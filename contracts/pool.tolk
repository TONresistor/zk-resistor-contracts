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
    // Only withdrawal transfers use the high query-id domain. Refund bounces
    // deliberately remain outside this recovery state machine.
    var bouncedBody = in.bouncedBody;
    bouncedBody.skipBouncedPrefix();
    if (bouncedBody.remainingBitsCount() < 32 + 64) {
        return;
    }
    val originalOpcode = bouncedBody.loadUint(32);
    if (originalOpcode != OP_JETTON_TRANSFER) {
        return;
    }
    val wireQueryId = bouncedBody.loadUint(64) as uint64;
    if ((wireQueryId & JETTON_WITHDRAW_QUERY_DOMAIN) == 0) {
        return;
    }
    val queryId: uint64 = wireQueryId & JETTON_QUERY_ID_MASK;

    var storage = lazy Storage.load();
    val jw = storage.jettonWallet;
    if (jw == null || in.senderAddress != jw!) {
        return;
    }

    val recoveryEntry = storage.withdrawals.get(queryId);
    if (!recoveryEntry.isFound) {
        return;
    }
    var recovery = recoveryEntry.loadValue().load();
    recovery.retryable = true;
    storage.withdrawals.set(queryId, recovery.toCell());
    storage.save();

    // Return the TON that came back with the failed transfer to the account
    // that funded this attempt. The pool never profits from a payout bounce.
    val gasRefund = createMessage({
        bounce: false,
        dest: recovery.lastPayer,
        value: 0,
    });
    // SAFETY: only the remaining value of this authenticated bounce is carried;
    // the pool's pre-existing balance is never swept.
    gasRefund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
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
// failure in handleDeposit.
fun refundDeposit(
    jw: address,
    msg: JettonTransferNotification,
    _reason: int,
) {
    // Pass the complete remaining inbound TON value through the pool's jetton
    // wallet. TEP-74 returns the unused part to responseDestination. This
    // avoids both trapping user TON and subsidizing malformed deposits from
    // the pool's own rent / relayer reserves.
    sendJettonWithRemainingValue(
        jw,
        msg.fromUser,
        msg.amount,
        msg.queryId & JETTON_QUERY_ID_MASK,
        msg.fromUser,
    );
}

fun isWellFormedDepositPayload(payloadSlice: slice): bool {
    if (
        payloadSlice.remainingBitsCount() != 32 + 64 + 256 + 256 ||
        payloadSlice.remainingRefsCount() != 1
    ) {
        return false;
    }

    var s = payloadSlice;
    if (s.loadUint(32) != OP_DEPOSIT_PAYLOAD) {
        return false;
    }
    s.skipBits(64 + 256 + 256);
    return isWellFormedZkProofCell(s.loadRef());
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
    if (rawPayload.remainingBitsCount() < 1) {
        return refundDeposit(jw!, msg, Errors.InvalidDepositPayload);
    }
    val eitherBit = rawPayload.loadUint(1);
    var payloadSlice = createEmptySlice();
    if (eitherBit == 0) {
        payloadSlice = rawPayload;
    } else {
        if (rawPayload.remainingBitsCount() != 0 || rawPayload.remainingRefsCount() != 1) {
            return refundDeposit(jw!, msg, Errors.InvalidDepositPayload);
        }
        payloadSlice = rawPayload.loadRef().beginParse();
    }

    if (!isWellFormedDepositPayload(payloadSlice)) {
        return refundDeposit(jw!, msg, Errors.InvalidDepositPayload);
    }

    val depositPayload = DepositPayload.fromSlice(payloadSlice);
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

    val depositExcess: coins = valueCoins - MIN_DEPOSIT_VALUE;
    val newRelayerReserve: coins = storage.relayerReserve + RELAYER_REIMBURSEMENT;
    if (contract.getOriginalBalance() - depositExcess < POOL_TON_RESERVE + newRelayerReserve) {
        return refundDeposit(jw!, msg, Errors.InsufficientBalance);
    }

    val leafIndex = merkle.insertCommitment(commitment, newRoot);
    storage.merkle = merkle.toCell();
    storage.relayerReserve = newRelayerReserve;
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
    assert (valueCoins >= MIN_WITHDRAW_GAS) throw Errors.InsufficientGas;
    assert (msg.queryId <= JETTON_QUERY_ID_MASK) throw Errors.InvalidQueryId;

    var storage = lazy Storage.load();
    val identity = storage.identity.load();
    var merkle = storage.merkle.load();

    val jw = storage.jettonWallet;
    assert (jw != null) throw Errors.JettonWalletNotSet;

    val recipientField = recipientToField(msg.recipient);

    // A queryId with an existing recovery record is a retry, never a second
    // withdrawal. The original root/nullifier were verified before the first
    // payout, so a retry may use that stored root even after it ages out of
    // rootHistory. A fresh proof binds any replacement recipient.
    val recoveryEntry = storage.withdrawals.get(msg.queryId);
    if (recoveryEntry.isFound) {
        var recovery = recoveryEntry.loadValue().load();
        assert (recovery.retryable) throw Errors.WithdrawalNotRetryable;
        assert (
            msg.root == recovery.root && msg.nullifierHash == recovery.nullifierHash
        ) throw Errors.InvalidRetry;

        val retryProof = msg.proof.load();
        val retryOk = verifyWithdrawProof(
            recovery.root,
            recovery.nullifierHash,
            recipientField,
            retryProof.proofA.load().raw,
            retryProof.proofB.load().raw,
            retryProof.proofC.load().raw,
        );
        assert (retryOk) throw Errors.InvalidWithdrawProof;

        recovery.lastPayer = sender;
        recovery.retryable = false;
        storage.withdrawals.set(msg.queryId, recovery.toCell());
        storage.save();

        val wireQueryId = msg.queryId | JETTON_WITHDRAW_QUERY_DOMAIN;
        sendJettonWithRemainingValue(
            jw!,
            msg.recipient,
            identity.denomination,
            wireQueryId,
            sender,
        );

        return;
    }

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
    // fees plus mainnet congestion headroom. The broadcaster's inbound gas
    // is excluded: it must not fund protocol solvency because the final
    // reserve/refund path also excludes it.
    val tonRequired: coins = POOL_TON_RESERVE + RELAYER_REIMBURSEMENT + JETTON_TRANSFER_GAS +
    30000000;
    val balanceAvailable: coins = contract.getOriginalBalance() - valueCoins;
    val otherReserves: coins = storage.relayerReserve - RELAYER_REIMBURSEMENT;
    assert (balanceAvailable >= tonRequired + otherReserves) throw Errors.InsufficientBalance;

    storage.relayerReserve = storage.relayerReserve - RELAYER_REIMBURSEMENT;
    merkle.markNullifierSpent(msg.nullifierHash);
    storage.merkle = merkle.toCell();
    storage
        .withdrawals
        .set(
            msg.queryId,
            (JettonWithdrawalRecovery {
                root: msg.root,
                nullifierHash: msg.nullifierHash,
                lastPayer: sender,
                retryable: false,
            }).toCell(),
        );
    storage.save();

    val wireQueryId = msg.queryId | JETTON_WITHDRAW_QUERY_DOMAIN;
    sendJetton(jw!, msg.recipient, recipientAmount, wireQueryId, sender);

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
        contract.getOriginalBalance() - valueCoins - RELAYER_REIMBURSEMENT,
        RESERVE_MODE_AT_MOST,
    );
    val senderPay = createMessage({
        bounce: false,
        dest: sender,
        value: 0,
    });
    // SAFETY: reserveToncoinsOnBalance pins the pool buffer and every remaining
    // relayer earmark before only the current withdrawal's surplus is carried.
    senderPay.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

// ============================================================================
// HELPERS
// ============================================================================

fun recipientToField(recipient: address): uint256 {
    val (workchain, recipientHash) = recipient.getWorkchainAndHash();
    assert (workchain == 0) throw Errors.InvalidRecipient;
    assert (recipientHash != 0) throw Errors.InvalidRecipient;
    return recipientHash & ADDRESS_FIELD_MASK;
}

fun sendJetton(
    jettonWallet: address,
    to: address,
    amount: coins,
    queryId: uint64,
    responseDestination: address,
) {
    val transferMessage = createMessage({
        bounce: true,
        dest: jettonWallet,
        value: JETTON_TRANSFER_GAS,
        body: JettonTransfer {
            queryId,
            amount,
            destination: to,
            responseDestination,
        },
    });
    transferMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun sendJettonWithRemainingValue(
    jettonWallet: address,
    to: address,
    amount: coins,
    queryId: uint64,
    responseDestination: address,
) {
    val transferMessage = createMessage({
        bounce: true,
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
    // self-funded refunds and retries so pool reserves cannot be drained.
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

get fun isWithdrawalRetryable(queryId: uint64): bool {
    val storage = lazy Storage.load();
    val recovery = storage.withdrawals.get(queryId);
    return recovery.isFound && recovery.loadValue().load().retryable;
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
