import "constants"
import "errors"
import "pool-types"
import "verifier-insert"
import "verifier-withdraw"

contract Pool {
    author: "ZKResistor"
    version: "1.0.0"
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
        InitWalletBinding => {
            handleInitWalletBinding(in.valueCoins, msg);
        }
        TakeWalletAddress => {
            handleTakeWalletAddress(in.senderAddress, msg);
        }
        JettonTransferNotification => {
            handleDeposit(in.senderAddress, in.valueCoins, msg);
        }
        Withdraw => {
            handleWithdraw(in.senderAddress, in.valueCoins, msg);
        }
        else => {
            // Empty body accepted as passive top-up / donation. The TON stays
            // on the pool as a storage-rent buffer above POOL_TON_RESERVE +
            // earmarks. Subsequent withdraws drain the buffer organically via
            // SEND_MODE_CARRY_ALL_BALANCE.
            assert (in.body.isEmpty()) throw Errors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    // Bounced JettonTransfer from handleWithdraw: jettons return to the
    // pool's JW, nullifier stays spent. Emit a WithdrawBouncedEvent so
    // indexers can correlate by queryId.
    var bouncedBody = in.bouncedBody;
    bouncedBody.skipBouncedPrefix();
    if (bouncedBody.remainingBitsCount() < 32 + 64) {
        return;
    }
    val originalOpcode = bouncedBody.loadUint(32);
    if (originalOpcode != OP_JETTON_TRANSFER) {
        return;
    }
    val queryId = bouncedBody.loadUint(64);

    val event = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0xdef001 },
        body: WithdrawBouncedEvent { queryId: queryId as uint64 },
    });
    event.send(SEND_MODE_REGULAR);
}

// ============================================================================
// WALLET BINDING: TEP-89 round-trip against jettonMaster
// ============================================================================

fun handleInitWalletBinding(valueCoins: coins, msg: InitWalletBinding) {
    val storage = lazy Storage.load();
    val identity = storage.identity.load();

    // Idempotent ping once bound.
    if (storage.jettonWallet != null) {
        return;
    }

    // Fund the query strictly from the inbound value, so retrigger spam
    // cannot drain the pool's own balance.
    val queryValue: coins = 50000000;
    val handlerBudget: coins = queryValue + 10000000;
    assert (valueCoins >= handlerBudget) throw Errors.InsufficientGas;

    val query = createMessage({
        bounce: true,
        dest: identity.jettonMaster,
        value: queryValue,
        body: ProvideWalletAddress {
            queryId: msg.queryId,
            ownerAddress: contract.getAddress(),
            includeAddress: false,
        },
    });
    query.send(SEND_MODE_REGULAR);
}

fun handleTakeWalletAddress(sender: address, msg: TakeWalletAddress) {
    var storage = lazy Storage.load();
    val identity = storage.identity.load();

    // Only the immutable jettonMaster can bind the wallet, single-shot.
    assert (sender == identity.jettonMaster) throw Errors.NotJettonMaster;
    assert (storage.jettonWallet == null) throw Errors.JettonWalletAlreadySet;

    storage.jettonWallet = msg.walletAddress;
    storage.save();

    val event = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0xdef002 },
        body: PoolReadyEvent { jettonWallet: msg.walletAddress },
    });
    event.send(SEND_MODE_REGULAR);
}

// ============================================================================
// DEPOSIT
// ============================================================================

// Return the deposited jettons to fromUser on any recoverable validation
// failure in handleDeposit. Emits a refund event for indexers.
fun refundDeposit(
    jw: address,
    msg: JettonTransferNotification,
    reason: int,
) {
    val event = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0xdef000 },
        body: DepositRefundedEvent {
            fromUser: msg.fromUser,
            amount: msg.amount,
            reason: reason as uint16,
        },
    });
    event.send(SEND_MODE_REGULAR);

    sendJetton(jw, msg.fromUser, msg.amount, msg.queryId);
}

fun handleDeposit(sender: address, valueCoins: coins, msg: JettonTransferNotification) {
    var storage = lazy Storage.load();
    val identity = storage.identity.load();
    var merkle = storage.merkle.load();

    // Non-refundable preconditions: if these fail the jettons are not
    // safely returnable, so we just stop processing.
    //   - jettonWallet not set: the pool is mid-init, no jw to send from.
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
        return refundDeposit(jw!, msg, Errors.InsufficientDepositValue);
    }

    if (msg.amount != identity.denomination) {
        return refundDeposit(jw!, msg, Errors.InvalidAmount);
    }

    if (merkle.nextIndex >= MERKLE_TREE_CAPACITY) {
        return refundDeposit(jw!, msg, Errors.TreeFull);
    }

    // Parse the user-supplied forward payload. TEP-74 encodes it as
    // (Either Cell ^Cell): bit 0 = inline, bit 1 = in ref.
    var rawPayload = msg.forwardPayload;
    val eitherBit = rawPayload.loadInt(1);
    val payloadSlice = eitherBit != 0 ? rawPayload.loadRef().beginParse() : rawPayload;

    val depositPayload = lazy DepositPayload.fromSlice(payloadSlice);
    val commitment = depositPayload.commitment;
    val newRoot = depositPayload.newRoot;

    if (merkle.isCommitmentUsed(commitment)) {
        return refundDeposit(jw!, msg, Errors.CommitmentAlreadyExists);
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
        return refundDeposit(jw!, msg, Errors.InvalidInsertProof);
    }

    val leafIndex = merkle.insertCommitment(commitment, newRoot);
    storage.merkle = merkle.toCell();
    storage.relayerReserve = storage.relayerReserve + RELAYER_REIMBURSEMENT;
    storage.save();

    val depositEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0xde9051 },
        body: DepositEvent {
            leafIndex,
            commitment,
            newRoot,
            fromUser: msg.fromUser,
        },
    });
    depositEvent.send(SEND_MODE_REGULAR);

    // Refund the user the TON attached beyond MIN_DEPOSIT_VALUE.
    // IGNORE_ERRORS so dust below the forwarding fee falls back to the
    // pool's rent buffer instead of reverting the whole transaction.
    val depositExcess: coins = valueCoins - MIN_DEPOSIT_VALUE;
    if (depositExcess > 0) {
        val refundExcess = createMessage({
            bounce: false,
            dest: msg.fromUser,
            value: depositExcess,
        });
        refundExcess.send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
    }

    // Defense-in-depth: the pool must hold POOL_TON_RESERVE plus every
    // relayer earmark after the deposit settles.
    assert (
        contract.getOriginalBalance() - depositExcess >= POOL_TON_RESERVE + storage.relayerReserve
    ) throw Errors.InsufficientBalance;
}

// ============================================================================
// WITHDRAW
// ============================================================================

fun handleWithdraw(sender: address, valueCoins: coins, msg: Withdraw) {
    assert (valueCoins >= MIN_WITHDRAW_GAS) throw Errors.InsufficientGas;

    var storage = lazy Storage.load();
    val identity = storage.identity.load();
    var merkle = storage.merkle.load();

    val jw = storage.jettonWallet;
    assert (jw != null) throw Errors.JettonWalletNotSet;

    // Derive the field the proof is bound to from msg.recipient: a
    // "recipient swap" produces a different field and fails the proof.
    // Reject malformed shapes (non-basechain, hash=0) so we never burn a
    // nullifier without a payable destination.
    val (workchain, recipientHash) = msg.recipient.getWorkchainAndHash();
    assert (workchain == 0) throw Errors.InvalidRecipient;
    assert (recipientHash != 0) throw Errors.InvalidRecipient;
    val recipientField: uint256 = recipientHash & ADDRESS_FIELD_MASK;

    assert (merkle.isKnownRoot(msg.root)) throw Errors.UnknownRoot;

    assert (!merkle.isNullifierSpent(msg.nullifierHash)) throw Errors.NullifierAlreadySpent;

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

    // Recipient gets the full denomination; the tx sender earns the
    // released RELAYER_REIMBURSEMENT.
    val recipientAmount = identity.denomination;

    // Nullifier-uniqueness guarantees deposits >= withdraws; assert
    // underflow defensively.
    assert (storage.relayerReserve >= RELAYER_REIMBURSEMENT) throw Errors.InsufficientReserve;

    // Solvency check before committing state: pool must cover the jetton
    // transfer, the sender payout, the external event, and all other
    // outstanding earmarks. 0.03 TON action-fee buffer absorbs forwarding
    // fees plus mainnet congestion headroom. getOriginalBalance() already
    // includes the credited inbound valueCoins.
    val tonRequired: coins = POOL_TON_RESERVE + RELAYER_REIMBURSEMENT + JETTON_TRANSFER_GAS +
    30000000;
    val balanceAvailable: coins = contract.getOriginalBalance();
    val otherReserves: coins = storage.relayerReserve - RELAYER_REIMBURSEMENT;
    assert (balanceAvailable >= tonRequired + otherReserves) throw Errors.InsufficientBalance;

    storage.relayerReserve = storage.relayerReserve - RELAYER_REIMBURSEMENT;
    merkle.markNullifierSpent(msg.nullifierHash);
    storage.merkle = merkle.toCell();
    storage.save();

    sendJetton(jw!, msg.recipient, recipientAmount, msg.queryId);

    val withdrawEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x717d3a },
        body: WithdrawEvent {
            nullifierHash: msg.nullifierHash,
            recipient: msg.recipient,
            payout: recipientAmount,
        },
    });
    withdrawEvent.send(SEND_MODE_REGULAR);

    // Pay the broadcaster their released earmark plus the unused part of the
    // gas they attached. The reserve pins the pool to (balance before this
    // message minus the released earmark), so the accumulated buffer is
    // preserved: every later withdraw still finds its own earmark intact and
    // no single broadcaster can sweep the pool.
    reserveToncoinsOnBalance(
        contract.getOriginalBalance() - RELAYER_REIMBURSEMENT,
        RESERVE_MODE_AT_MOST,
    );
    val senderPay = createMessage({
        bounce: false,
        dest: sender,
        value: 0,
    });
    senderPay.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

// ============================================================================
// HELPERS
// ============================================================================

fun sendJetton(jettonWallet: address, to: address, amount: coins, queryId: uint64) {
    val transferMessage = createMessage({
        bounce: true,
        dest: jettonWallet,
        value: JETTON_TRANSFER_GAS,
        body: JettonTransfer {
            queryId,
            amount,
            destination: to,
            responseDestination: to,
        },
    });
    transferMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
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

get fun treeDepth(): int {
    return MERKLE_TREE_DEPTH;
}

// ============================================================================
// PROOF PREVIEW (off-chain only)
// ============================================================================
//
// Read-only previews for off-chain callers. Both run the real pairing
// regardless of MOCK_VERIFIER and cannot mutate state.

get fun previewInsertProof(
    oldRoot: uint256,
    newRoot: uint256,
    commitment: uint256,
    leafIndex: uint32,
    proofA: slice,
    proofB: slice,
    proofC: slice,
): bool {
    return verifyInsertProofForced(
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
    return verifyWithdrawProofForced(
        root,
        nullifierHash,
        recipientField,
        proofA,
        proofB,
        proofC,
    );
}
