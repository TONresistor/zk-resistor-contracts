import "constants"
import "errors"
import "pool-types" // MerkleState helpers (shared)
import "ton-pool-types"
import "verifier-insert"
import "verifier-withdraw"

contract TonPool {
    author: "ZKResistor"
    version: "1.0.0"
    description: "ZK mixer pool for native TON. Proof binds recipient by construction; sender of withdraw tx receives RELAYER_REIMBURSEMENT."
    storage: TonPoolStorage
    incomingMessages: AllowedTonMessage
}

// ============================================================================
// ENTRYPOINT
// ============================================================================

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedTonMessage.fromSlice(in.body);

    match (msg) {
        TonDepositPayload => {
            handleDeposit(in.senderAddress, in.valueCoins, msg);
        }
        TonWithdraw => {
            handleWithdraw(in.senderAddress, in.valueCoins, msg);
        }
        else => {
            // Empty body accepted as factory's deploy message (init surplus)
            // or a passive top-up. The TON stays on the pool as a storage-rent
            // buffer above POOL_TON_RESERVE + earmarks. Subsequent withdraws
            // drain the buffer organically via SEND_MODE_CARRY_ALL_BALANCE.
            assert (in.body.isEmpty()) throw Errors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {
    // No state changes on bounces. Funds return to the pool's balance and
    // stay there; storage counters reflect committed state, not in-flight
    // payouts, so any inconsistency self-heals.
}

// ============================================================================
// DEPOSIT
// ============================================================================

fun refundDeposit(fromUser: address, _amount: coins, _reason: int) {
    // CARRY_ALL_REMAINING_MESSAGE_VALUE forwards the inbound value minus
    // action fees. Paying fees from the pool's own balance would let a
    // spammer drain a freshly-deployed pool by triggering failing deposits.
    val refundMsg = createMessage({
        bounce: false,
        dest: fromUser,
        value: 0,
    });
    refundMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

fun handleDeposit(_sender: address, valueCoins: coins, msg: TonDepositPayload) {
    var storage = lazy TonPoolStorage.load();
    val identity = storage.identity.load();
    var merkle = storage.merkle.load();

    // Deposit must attach denomination + MIN_DEPOSIT_VALUE. Any excess is
    // refunded to msg.fromUser at the end of the success path.
    val requiredValue: coins = identity.denomination + MIN_DEPOSIT_VALUE;
    if (valueCoins < requiredValue) {
        return refundDeposit(msg.fromUser, valueCoins, Errors.InsufficientDepositValue);
    }

    if (merkle.nextIndex >= MERKLE_TREE_CAPACITY) {
        return refundDeposit(msg.fromUser, valueCoins, Errors.TreeFull);
    }

    if (merkle.isCommitmentUsed(msg.commitment)) {
        return refundDeposit(msg.fromUser, valueCoins, Errors.CommitmentAlreadyExists);
    }

    if (!isWellFormedZkProofCell(msg.insertProof)) {
        return refundDeposit(msg.fromUser, valueCoins, Errors.InvalidInsertProof);
    }

    val depositExcess: coins = valueCoins - requiredValue;
    val newRelayerReserve: coins = storage.relayerReserve + RELAYER_REIMBURSEMENT;
    val newPendingWithdrawTon: coins = storage.pendingWithdrawTon + identity.denomination;
    if (
        contract.getOriginalBalance() - depositExcess <
        POOL_TON_RESERVE + newRelayerReserve + newPendingWithdrawTon
    ) {
        return refundDeposit(msg.fromUser, valueCoins, Errors.InsufficientBalance);
    }

    val proof = msg.insertProof.load();
    val ok = verifyInsertProof(
        merkle.currentRoot,
        msg.newRoot,
        msg.commitment,
        merkle.nextIndex,
        proof.proofA.load().raw,
        proof.proofB.load().raw,
        proof.proofC.load().raw,
    );
    if (!ok) {
        return refundDeposit(msg.fromUser, valueCoins, Errors.InvalidInsertProof);
    }

    val leafIndex = merkle.insertCommitment(msg.commitment, msg.newRoot);
    storage.merkle = merkle.toCell();
    storage.relayerReserve = newRelayerReserve;
    storage.pendingWithdrawTon = newPendingWithdrawTon;
    storage.save();

    val depositEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x00de9051 },
        body: TonDepositEvent {
            leafIndex,
            commitment: msg.commitment,
            newRoot: msg.newRoot,
            fromUser: msg.fromUser,
        },
    });
    depositEvent.send(SEND_MODE_REGULAR);

    // Refund the user the TON attached beyond requiredValue. IGNORE_ERRORS
    // so dust below the forwarding fee falls back to the pool's rent
    // buffer instead of reverting the whole transaction.
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

fun handleWithdraw(sender: address, valueCoins: coins, msg: TonWithdraw) {
    assert (valueCoins >= MIN_WITHDRAW_GAS) throw Errors.InsufficientGas;

    var storage = lazy TonPoolStorage.load();
    val identity = storage.identity.load();
    var merkle = storage.merkle.load();

    // Derive the field the proof is bound to from msg.recipient. Reject
    // malformed shapes (non-basechain, hash=0) so we never burn a nullifier
    // without a payable destination.
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

    val recipientAmount = identity.denomination;

    // Nullifier-uniqueness guarantees deposits >= withdraws; assert
    // underflow defensively.
    assert (storage.relayerReserve >= RELAYER_REIMBURSEMENT) throw Errors.InsufficientReserve;
    assert (storage.pendingWithdrawTon >= identity.denomination) throw Errors.InsufficientReserve;

    // Solvency check before committing state: pool must cover the recipient
    // payout, the sender payout, the external event, and all other
    // outstanding earmarks. 0.03 TON action-fee buffer absorbs forwarding
    // fees plus mainnet congestion headroom. The broadcaster's inbound gas
    // is excluded: it must not fund protocol solvency because the final
    // reserve/refund path also excludes it.
    val tonRequired: coins = POOL_TON_RESERVE + recipientAmount + RELAYER_REIMBURSEMENT + 30000000;
    val balanceAvailable: coins = contract.getOriginalBalance() - valueCoins;
    val otherReserves: coins = (storage.relayerReserve - RELAYER_REIMBURSEMENT) +
    (storage.pendingWithdrawTon - identity.denomination);
    assert (balanceAvailable >= tonRequired + otherReserves) throw Errors.InsufficientBalance;

    storage.relayerReserve = storage.relayerReserve - RELAYER_REIMBURSEMENT;
    storage.pendingWithdrawTon = storage.pendingWithdrawTon - identity.denomination;
    merkle.markNullifierSpent(msg.nullifierHash);
    storage.merkle = merkle.toCell();
    storage.save();

    // bounce: false activates fresh wallets on first delivery, important
    // for anonymity since the recipient is often a fresh address.
    val recipientPay = createMessage({
        bounce: false,
        dest: msg.recipient,
        value: recipientAmount,
    });
    recipientPay.send(SEND_MODE_REGULAR);

    val withdrawEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x00717d3a },
        body: TonWithdrawEvent {
            nullifierHash: msg.nullifierHash,
            recipient: msg.recipient,
            payout: recipientAmount,
        },
    });
    withdrawEvent.send(SEND_MODE_REGULAR);

    // Pay the broadcaster their released earmark plus the unused part of the
    // gas they attached. The reserve pins the pool to (balance before this
    // message minus the released earmark minus the recipient payout), so the
    // accumulated buffer is preserved: every later withdraw still finds its
    // own earmark + denomination intact and no broadcaster can sweep the pool.
    reserveToncoinsOnBalance(
        contract.getOriginalBalance() - valueCoins - RELAYER_REIMBURSEMENT - recipientAmount,
        RESERVE_MODE_AT_MOST,
    );
    val senderPay = createMessage({
        bounce: false,
        dest: sender,
        value: 0,
    });
    // SAFETY: reserveToncoinsOnBalance pins the pool buffer, every remaining
    // earmark, and every pending native payout before the surplus is carried.
    senderPay.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

// ============================================================================
// GETTERS
// ============================================================================

get fun factory(): address {
    val storage = lazy TonPoolStorage.load();
    return storage.identity.load().factory;
}

get fun denomination(): coins {
    val storage = lazy TonPoolStorage.load();
    return storage.identity.load().denomination;
}

get fun currentRoot(): uint256 {
    val storage = lazy TonPoolStorage.load();
    return storage.merkle.load().currentRoot;
}

get fun nextIndex(): uint32 {
    val storage = lazy TonPoolStorage.load();
    return storage.merkle.load().nextIndex;
}

get fun relayerReserve(): coins {
    val storage = lazy TonPoolStorage.load();
    return storage.relayerReserve;
}

get fun pendingWithdrawTon(): coins {
    val storage = lazy TonPoolStorage.load();
    return storage.pendingWithdrawTon;
}

get fun treeDepth(): int {
    return MERKLE_TREE_DEPTH;
}
