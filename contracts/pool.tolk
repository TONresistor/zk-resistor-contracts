import "@stdlib/exotic-cells"
import "constants"
import "deployment-types"
import "errors"
import "pool-types"
import "recipient-binding"
import "sparse-set"
import "verifier-insert"
import "verifier-withdraw"

contract Pool {
    author: "ZKResistor"
    version: "2.0.0"
    description: "ZK mixer pool (jetton). Proof binds recipient by construction; sender of withdraw tx receives RELAYER_REIMBURSEMENT."
    storage: Storage
    incomingMessages: AllowedMessage
}

// ============================================================================
// ENTRYPOINT
// ============================================================================

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessage.fromSlice(in.body);

    match (msg) {
        PoolConfirmPoolDeployment => {
            msg.forceLoadLazyObject().assertEnd();
            handleConfirmPoolDeployment(in.valueCoins, msg);
        }
        InitWalletBinding => {
            msg.forceLoadLazyObject().assertEnd();
            handleInitWalletBinding(in.valueCoins, msg);
        }
        TakeWalletAddress => {
            msg.forceLoadLazyObject().assertEnd();
            handleTakeWalletAddress(in.senderAddress, msg);
        }
        JettonTransferNotification => {
            handleDeposit(in.senderAddress, in.valueCoins, msg);
        }
        Withdraw => {
            msg.forceLoadLazyObject().assertEnd();
            handleWithdraw(in.senderAddress, in.valueCoins, msg);
        }
        else => {
            // Empty body accepted as passive top-up / donation. The TON stays
            // on the pool as a storage-rent buffer above POOL_TON_RESERVE +
            // earmarks. The withdraw carry path reserves the complete pre-message
            // balance, so later callers cannot sweep this buffer.
            assert (in.body.isEmpty()) throw Errors.InvalidMessage;
        }
    }
}

// ============================================================================
// WALLET BINDING: TEP-89 round-trip against jettonMaster
// ============================================================================

const POOL_CONFIRM_VALUE: coins = 10000000 // 0.01 TON
const WALLET_ADDRESS_QUERY_VALUE: coins = 50000000 // 0.05 TON
const DEPLOY_TRIGGER_HANDLER_BUDGET: coins = 10000000 // 0.01 TON

fun sendPoolDeployConfirmed(identity: PoolIdentity, queryId: uint64) {
    val confirmation = createMessage({
        bounce: BounceMode.NoBounce,
        dest: identity.factory,
        value: POOL_CONFIRM_VALUE,
        body: PoolDeployConfirmed {
            queryId,
            jettonMaster: identity.jettonMaster,
            denomination: identity.denomination,
        },
    });
    confirmation.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun sendWalletAddressQuery(identity: PoolIdentity, queryId: uint64) {
    val query = createMessage({
        bounce: BounceMode.NoBounce,
        dest: identity.jettonMaster,
        value: WALLET_ADDRESS_QUERY_VALUE,
        body: ProvideWalletAddress {
            queryId,
            ownerAddress: contract.getAddress(),
            includeAddress: false,
        },
    });
    query.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun poolObligations(storage: Storage): coins {
    return storage.merkle.load().poolRentRunway() + storage.relayerReserve;
}

fun reservePoolObligations(storage: Storage) {
    reserveToncoinsOnBalance(
        poolObligations(storage),
        RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
    );
}

fun reservePoolPreMessageBalance(storage: Storage, valueCoins: coins) {
    val originalBalance = contract.getOriginalBalance();
    val balanceBeforeMessage: coins = originalBalance - min(originalBalance, valueCoins);
    reserveToncoinsOnBalance(
        max(balanceBeforeMessage, poolObligations(storage)),
        RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
    );
}

fun handleDeploymentTrigger(valueCoins: coins, queryId: uint64) {
    val storage = lazy Storage.load();
    val identity = storage.identity.load();

    if (storage.jettonWallet != null) {
        assert (
            valueCoins >= POOL_CONFIRM_VALUE + DEPLOY_TRIGGER_HANDLER_BUDGET
        ) throw Errors.InsufficientGas;
        reservePoolPreMessageBalance(storage, valueCoins);
        sendPoolDeployConfirmed(identity, queryId);
    } else {
        assert (
            valueCoins >= WALLET_ADDRESS_QUERY_VALUE + DEPLOY_TRIGGER_HANDLER_BUDGET
        ) throw Errors.InsufficientGas;
        reservePoolPreMessageBalance(storage, valueCoins);
        sendWalletAddressQuery(identity, queryId);
    }
}

fun handleConfirmPoolDeployment(valueCoins: coins, msg: PoolConfirmPoolDeployment) {
    handleDeploymentTrigger(valueCoins, msg.queryId);
}

fun handleInitWalletBinding(valueCoins: coins, msg: InitWalletBinding) {
    handleDeploymentTrigger(valueCoins, msg.queryId);
}

fun handleTakeWalletAddress(sender: address, msg: TakeWalletAddress) {
    var storage = lazy Storage.load();
    val identity = storage.identity.load();

    // Only the immutable jettonMaster can bind the wallet, single-shot.
    assert (sender == identity.jettonMaster) throw Errors.NotJettonMaster;
    assert (storage.jettonWallet == null) throw Errors.JettonWalletAlreadySet;

    storage.jettonWallet = msg.walletAddress;
    storage.save();

    // The authenticated TEP-89 response activates the Pool. Reserve its rent
    // and relayer obligations before the event and Factory confirmation.
    reservePoolObligations(storage);
    val event = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x00def002 },
        body: PoolReadyEvent { jettonWallet: msg.walletAddress },
    });
    event.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
    sendPoolDeployConfirmed(storage.identity.load(), msg.queryId);
}

// ============================================================================
// DEPOSIT
// ============================================================================

// Return the deposited jettons to fromUser on any recoverable validation
// failure in handleDeposit.
fun refundDeposit(
    jw: address,
    msg: JettonTransferNotification,
) {
    // Pass the complete remaining inbound TON value through the pool's jetton
    // wallet. TEP-74 returns the unused part to responseDestination. This
    // avoids both trapping user TON and subsidizing malformed deposits from
    // the pool's own rent / relayer reserves.
    sendJettonWithRemainingValue(
        jw,
        msg.fromUser,
        msg.amount,
        msg.queryId,
        msg.fromUser,
    );
}

fun isWellFormedDepositPayload(payloadSlice: slice): bool {
    if (
        payloadSlice.remainingBitsCount() != 32 + 64 + 256 + 256 ||
        payloadSlice.remainingRefsCount() != 2
    ) {
        return false;
    }

    var s = payloadSlice;
    if (s.loadUint(32) != OP_DEPOSIT_PAYLOAD) {
        return false;
    }
    s.loadUint(64);  // queryId
    s.loadUint(256); // commitment
    s.loadUint(256); // newRoot
    if (!isWellFormedZkProofCell(s.loadRef())) {
        return false;
    }
    s.loadRef();     // sparse witness is validated by sparseSetApplyUpdate
    return true;
}

fun handleDeposit(sender: address, valueCoins: coins, msg: JettonTransferNotification) {
    var storage = lazy Storage.load();
    val identity = storage.identity.load();
    var merkle = storage.merkle.load();

    // Non-refundable preconditions: if these fail the jettons are not
    // safely returnable, so we just stop processing.
    //   - jettonWallet not set: the pool is still pending activation.
    //   - sender != our jw: this is a forged notification with arbitrary
    //     fromUser; refunding would gift jettons to an attacker who never
    //     actually deposited anything via the standard TEP-74 flow.
    val jw = storage.jettonWallet;
    if (jw == null) {
        return;
    }
    if (sender != jw!) {
        return;
    }

    // From here on, every failure mode results in a refund to fromUser.

    // Deposit must self-fund its RELAYER_REIMBURSEMENT earmark. Without
    // this, spam deposits could inflate relayerReserve above the pool's
    // actual balance and starve future withdraws.
    if (valueCoins < MIN_DEPOSIT_VALUE) {
        return refundDeposit(jw!, msg);
    }

    if (msg.amount != identity.denomination) {
        return refundDeposit(jw!, msg);
    }

    if (merkle.nextIndex >= MERKLE_TREE_CAPACITY) {
        return refundDeposit(jw!, msg);
    }

    // Parse the user-supplied forward payload. TEP-74 encodes it as
    // (Either Cell ^Cell): bit 0 = inline, bit 1 = in ref.
    var rawPayload = msg.forwardPayload;
    if (rawPayload.remainingBitsCount() < 1) {
        return refundDeposit(jw!, msg);
    }
    val eitherBit = rawPayload.loadUint(1);
    var payloadSlice = createEmptySlice();
    if (eitherBit == 0) {
        payloadSlice = rawPayload;
    } else {
        if (rawPayload.remainingBitsCount() != 0 || rawPayload.remainingRefsCount() != 1) {
            return refundDeposit(jw!, msg);
        }
        val payloadCell = rawPayload.loadRef();
        val (ordinaryPayload, payloadIsExotic) = payloadCell.beginParseSpecial();
        if (payloadIsExotic) {
            return refundDeposit(jw!, msg);
        }
        payloadSlice = ordinaryPayload;
    }

    if (!isWellFormedDepositPayload(payloadSlice)) {
        return refundDeposit(jw!, msg);
    }

    val depositPayload = DepositPayload.fromSlice(payloadSlice);
    val commitment = depositPayload.commitment;
    val newRoot = depositPayload.newRoot;

    val commitmentUpdate = merkle.prepareSparseSetUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        commitment,
        depositPayload.commitmentSetProof,
    );
    if (commitmentUpdate.status != SparseSetUpdateStatus.Ok) {
        return refundDeposit(jw!, msg);
    }

    val proof = depositPayload.insertProof.load();
    val ok = verifyInsertProof(
        merkle.currentRoot,
        newRoot,
        commitment,
        merkle.nextIndex,
        proof.proofA.load().raw,
        proof.proofB.load().raw,
        proof.proofC.load().raw,
    );
    if (!ok) {
        return refundDeposit(jw!, msg);
    }

    val leafIndex = merkle.insertCommitmentBounded(newRoot, commitmentUpdate);
    val depositExcess: coins = valueCoins - MIN_DEPOSIT_VALUE;
    val newRelayerReserve: coins = storage.relayerReserve + RELAYER_REIMBURSEMENT;
    val newRentRunway = merkle.poolRentRunway();
    if (
        contract.getOriginalBalance() - depositExcess <
        newRentRunway + newRelayerReserve + POOL_DEPOSIT_FEE_MARGIN
    ) {
        return refundDeposit(jw!, msg);
    }

    storage.merkle = merkle.toCell();
    storage.relayerReserve = newRelayerReserve;
    storage.save();

    val depositEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x00de9052 },
        body: DepositEvent {
            leafIndex,
            commitment,
            newRoot,
            fromUser: msg.fromUser,
            sparseUpdate: (SparseSetEventUpdate {
                bucketId: commitmentUpdate.bucketId as uint8,
                newRoot: commitmentUpdate.newRoot,
            }).toCell(),
        },
    });
    depositEvent.send(SEND_MODE_REGULAR);

    // Refund the user the TON attached beyond MIN_DEPOSIT_VALUE.
    // IGNORE_ERRORS so dust below the forwarding fee falls back to the
    // pool's rent buffer instead of reverting the whole transaction.
    if (depositExcess > 0) {
        val refundExcess = createMessage({
            bounce: false,
            dest: msg.fromUser,
            value: depositExcess,
        });
        refundExcess.send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
    }
}

// ============================================================================
// WITHDRAW
// ============================================================================

fun handleWithdraw(sender: address, valueCoins: coins, msg: Withdraw) {
    assert (valueCoins >= MIN_JETTON_WITHDRAW_GAS) throw Errors.InsufficientGas;

    var storage = lazy Storage.load();
    val identity = storage.identity.load();
    var merkle = storage.merkle.load();

    val jw = storage.jettonWallet;
    assert (jw != null) throw Errors.JettonWalletNotSet;
    assert (storage.withdrawalCount < merkle.nextIndex) throw Errors.WithdrawalCapacityReached;

    val recipientField = recipientToField(msg.recipient);
    assert (merkle.isKnownRoot(msg.root)) throw Errors.UnknownRoot;

    val proof = msg.proof.load();
    val ok = verifyWithdrawProof(
        msg.root,
        msg.nullifierHash,
        recipientField,
        proof.proofA.load().raw,
        proof.proofB.load().raw,
        proof.proofC.load().raw,
    );
    assert (ok) throw Errors.InvalidWithdrawProof;

    val nullifierUpdate = merkle.prepareSparseSetUpdate(
        SPARSE_SET_NULLIFIER_DOMAIN,
        msg.nullifierHash,
        msg.nullifierSetProof,
    );
    if (nullifierUpdate.status == SparseSetUpdateStatus.StaleRoot) {
        throw Errors.StaleSparseSetRoot;
    }
    if (nullifierUpdate.status == SparseSetUpdateStatus.NonEmptyLeafOrInvalidWitness) {
        throw Errors.NullifierAlreadySpent;
    }
    assert (nullifierUpdate.status == SparseSetUpdateStatus.Ok) throw Errors.InvalidSparseSetProof;

    // Recipient gets the full denomination; the tx sender earns the
    // released RELAYER_REIMBURSEMENT.
    val recipientAmount = identity.denomination;

    // Nullifier-uniqueness guarantees deposits >= withdraws; assert
    // underflow defensively.
    assert (storage.relayerReserve >= RELAYER_REIMBURSEMENT) throw Errors.InsufficientReserve;

    // Solvency check before committing state: pool must cover the jetton
    // transfer, the sender payout, the external event, and all other
    // outstanding earmarks. 0.03 TON action-fee buffer absorbs forwarding
    // fees plus mainnet congestion headroom. The broadcaster's inbound gas
    // is excluded: it must not fund protocol solvency because the final
    // reserve/refund path also excludes it.
    val balanceAvailable: coins = contract.getOriginalBalance() - valueCoins;
    val currentRentRunway = merkle.poolRentRunway();
    // The fixed payout value, its fees, and compute are caller-funded. The
    // pre-message balance only has to preserve rent plus every relayer earmark;
    // no withdrawal may consume another note's buffer.
    assert (
        balanceAvailable >= currentRentRunway + storage.relayerReserve
    ) throw Errors.InsufficientBalance;

    storage.withdrawalCount += 1;
    storage.relayerReserve -= RELAYER_REIMBURSEMENT;
    merkle.markNullifierSpentBounded(nullifierUpdate);
    val newRentRunway = merkle.poolRentRunway();
    // A nullifier insertion can only preserve or add one sparse bucket.
    val rentGrowth: coins = newRentRunway - currentRentRunway;
    storage.merkle = merkle.toCell();
    storage.save();

    sendJettonPayout(
        jw!,
        msg.recipient,
        recipientAmount,
        msg.clientQueryId,
        sender,
    );

    val withdrawEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x00717d3c },
        body: WithdrawalAcceptedEvent {
            clientQueryId: msg.clientQueryId,
            nullifierHash: msg.nullifierHash,
            recipient: msg.recipient,
            payout: recipientAmount,
            sparseUpdate: (SparseSetEventUpdate {
                bucketId: nullifierUpdate.bucketId as uint8,
                newRoot: nullifierUpdate.newRoot,
            }).toCell(),
        },
    });
    withdrawEvent.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

    // Pay the broadcaster their released earmark plus the unused part of the
    // gas they attached. The reserve pins the pool to (balance before this
    // message minus the released earmark), so the accumulated buffer is
    // preserved: every later withdraw still finds its own earmark intact and
    // no single broadcaster can sweep the pool.
    reserveToncoinsOnBalance(
        contract.getOriginalBalance() - valueCoins - RELAYER_REIMBURSEMENT + rentGrowth,
        RESERVE_MODE_AT_MOST,
    );
    val senderPay = createMessage({
        bounce: false,
        dest: sender,
        value: 0,
    });
    // SAFETY: reserveToncoinsOnBalance pins the pool buffer and every remaining
    // relayer earmark before only the current withdrawal's surplus is carried.
    senderPay.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun sendJettonPayout(
    jettonWallet: address,
    to: address,
    amount: coins,
    queryId: uint64,
    responseDestination: address,
) {
    val transferMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: jettonWallet,
        value: JETTON_PAYOUT_VALUE,
        body: JettonTransfer {
            queryId,
            amount,
            destination: to,
            responseDestination,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: null,
        },
    });
    transferMessage.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun sendJettonWithRemainingValue(
    jettonWallet: address,
    to: address,
    amount: coins,
    queryId: uint64,
    responseDestination: address,
) {
    val transferMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: jettonWallet,
        value: 0,
        body: JettonTransfer {
            queryId,
            amount,
            destination: to,
            responseDestination,
        },
    });
    // SAFETY: carries only the current inbound message value. Used for
    // self-funded refunds so pool reserves cannot be drained.
    transferMessage.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// ============================================================================
// GETTERS
// ============================================================================

get fun jettonMaster(): address {
    val storage = lazy Storage.load();
    return storage.identity.load().jettonMaster;
}

get fun factory(): address {
    val storage = lazy Storage.load();
    return storage.identity.load().factory;
}

get fun jettonWallet(): address? {
    val storage = lazy Storage.load();
    return storage.jettonWallet;
}

get fun denomination(): coins {
    val storage = lazy Storage.load();
    return storage.identity.load().denomination;
}

get fun currentRoot(): uint256 {
    val storage = lazy Storage.load();
    return storage.merkle.load().currentRoot;
}

get fun nextIndex(): uint32 {
    val storage = lazy Storage.load();
    return storage.merkle.load().nextIndex;
}

get fun relayerReserve(): coins {
    val storage = lazy Storage.load();
    return storage.relayerReserve;
}

get fun rentRunway(): coins {
    return Storage.load().merkle.load().poolRentRunway();
}

get fun sparseRoot(domain: uint32, bucketId: uint8): uint256 {
    val storage = lazy Storage.load();
    return storage.merkle.load().sparseSetRoot(domain, bucketId);
}

get fun withdrawalCount(): uint32 {
    return Storage.load().withdrawalCount;
}

get fun treeDepth(): int {
    return MERKLE_TREE_DEPTH;
}

// ============================================================================
// PROOF PREVIEW (off-chain only)
// ============================================================================
//
// Read-only previews for off-chain callers. Both run the same real pairing
// verifier as the state-changing handlers and cannot mutate state.

get fun previewInsertProof(
    oldRoot: uint256,
    newRoot: uint256,
    commitment: uint256,
    leafIndex: uint32,
    proofA: slice,
    proofB: slice,
    proofC: slice,
): bool {
    return verifyInsertProof(
        oldRoot,
        newRoot,
        commitment,
        leafIndex,
        proofA,
        proofB,
        proofC,
    );
}

get fun previewWithdrawProof(
    root: uint256,
    nullifierHash: uint256,
    recipientField: uint256,
    proofA: slice,
    proofB: slice,
    proofC: slice,
): bool {
    return verifyWithdrawProof(
        root,
        nullifierHash,
        recipientField,
        proofA,
        proofB,
        proofC,
    );
}
