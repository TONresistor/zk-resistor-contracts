import "constants"
import "deployment-types"
import "errors"
import "pool-types" // MerkleState helpers (shared)
import "recipient-binding"
import "sparse-set"
import "ton-pool-types"
import "verifier-insert"
import "verifier-withdraw"

contract TonPool {
    author: "ZKResistor"
    version: "2.0.0"
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
        TonPoolConfirmPoolDeployment => {
            msg.forceLoadLazyObject().assertEnd();
            handleConfirmPoolDeployment(in.valueCoins, msg);
        }
        TonDepositPayload => {
            val trailing = msg.forceLoadLazyObject();
            if (!trailing.isEmpty()) {
                return refundDeposit(msg.fromUser);
            }
            handleDeposit(in.senderAddress, in.valueCoins, msg);
        }
        TonWithdraw => {
            val trailing = msg.forceLoadLazyObject();
            assert (trailing.isEmpty()) throw Errors.InvalidMessage;
            handleWithdraw(in.senderAddress, in.valueCoins, msg);
        }
        else => {
            // Empty body accepted as factory's deploy message (init surplus)
            // or a passive top-up. The TON stays on the pool as a storage-rent
            // buffer above POOL_TON_RESERVE + earmarks. Withdraw reserves the
            // complete pre-message balance, so later callers cannot sweep it.
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
// FACTORY DEPLOYMENT CONFIRMATION
// ============================================================================

const TON_POOL_CONFIRM_VALUE: coins = 10000000 // 0.01 TON
const TON_POOL_CONFIRM_HANDLER_BUDGET: coins = 10000000 // 0.01 TON

fun handleConfirmPoolDeployment(valueCoins: coins, msg: TonPoolConfirmPoolDeployment) {
    assert (
        valueCoins >= TON_POOL_CONFIRM_VALUE + TON_POOL_CONFIRM_HANDLER_BUDGET
    ) throw Errors.InsufficientGas;

    val identity = lazy TonPoolStorage.load().identity.load();
    val confirmation = createMessage({
        bounce: BounceMode.NoBounce,
        dest: identity.factory,
        value: TON_POOL_CONFIRM_VALUE,
        body: PoolDeployConfirmed {
            queryId: msg.queryId,
            jettonMaster: null,
            denomination: identity.denomination,
        },
    });
    confirmation.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// ============================================================================
// DEPOSIT
// ============================================================================

fun refundDeposit(fromUser: address) {
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
        return refundDeposit(msg.fromUser);
    }

    if (merkle.nextIndex >= MERKLE_TREE_CAPACITY) {
        return refundDeposit(msg.fromUser);
    }

    if (!isWellFormedZkProofCell(msg.insertProof)) {
        return refundDeposit(msg.fromUser);
    }

    val commitmentUpdate = merkle.prepareSparseSetUpdate(
        SPARSE_SET_COMMITMENT_DOMAIN,
        msg.commitment,
        msg.commitmentSetProof,
    );
    if (commitmentUpdate.status != SparseSetUpdateStatus.Ok) {
        return refundDeposit(msg.fromUser);
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
        return refundDeposit(msg.fromUser);
    }

    val leafIndex = merkle.insertCommitmentBounded(msg.newRoot, commitmentUpdate);
    val depositExcess: coins = valueCoins - requiredValue;
    val newRelayerReserve: coins = storage.relayerReserve + RELAYER_REIMBURSEMENT;
    val newPendingWithdrawTon: coins = storage.pendingWithdrawTon + identity.denomination;
    val newRentRunway = merkle.poolRentRunway();
    if (
        contract.getOriginalBalance() - depositExcess <
        newRentRunway + newRelayerReserve + newPendingWithdrawTon + POOL_DEPOSIT_FEE_MARGIN
    ) {
        return refundDeposit(msg.fromUser);
    }

    storage.merkle = merkle.toCell();
    storage.relayerReserve = newRelayerReserve;
    storage.pendingWithdrawTon = newPendingWithdrawTon;
    storage.save();

    val depositEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x00de9052 },
        body: TonDepositEvent {
            leafIndex,
            commitment: msg.commitment,
            newRoot: msg.newRoot,
            fromUser: msg.fromUser,
            sparseUpdate: (SparseSetEventUpdate {
                bucketId: commitmentUpdate.bucketId as uint8,
                newRoot: commitmentUpdate.newRoot,
            }).toCell(),
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

    // Domain-hash the complete canonical address before proof verification so
    // changing any address bit invalidates the proof before state is written.
    val recipientField = recipientToField(msg.recipient);

    assert (merkle.isKnownRoot(msg.root)) throw Errors.UnknownRoot;
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

    // Before this caller-funded transaction, the pool must already cover its
    // measured rent runway and every outstanding reward/native payout.
    val balanceAvailable: coins = contract.getOriginalBalance() - valueCoins;
    val currentRentRunway = merkle.poolRentRunway();
    assert (
        balanceAvailable >= currentRentRunway + storage.relayerReserve + storage.pendingWithdrawTon
    ) throw Errors.InsufficientBalance;

    storage.relayerReserve = storage.relayerReserve - RELAYER_REIMBURSEMENT;
    storage.pendingWithdrawTon = storage.pendingWithdrawTon - identity.denomination;
    merkle.markNullifierSpentBounded(nullifierUpdate);
    val newRentRunway = merkle.poolRentRunway();
    val rentGrowth: coins = newRentRunway - currentRentRunway;
    storage.merkle = merkle.toCell();
    storage.save();

    // bounce: false activates fresh wallets on first delivery, important
    // for anonymity since the recipient is often a fresh address.
    val recipientPay = createMessage({
        bounce: false,
        dest: msg.recipient,
        value: recipientAmount,
    });
    recipientPay.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

    val withdrawEvent = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: 0x00717d3b },
        body: TonWithdrawEvent {
            nullifierHash: msg.nullifierHash,
            recipient: msg.recipient,
            payout: recipientAmount,
            sparseUpdate: (SparseSetEventUpdate {
                bucketId: nullifierUpdate.bucketId as uint8,
                newRoot: nullifierUpdate.newRoot,
            }).toCell(),
        },
    });
    withdrawEvent.send(SEND_MODE_REGULAR);

    // Pay the broadcaster their released earmark plus the unused part of the
    // gas they attached. The reserve pins the pool to (balance before this
    // message minus the released earmark minus the recipient payout), so the
    // accumulated buffer is preserved: every later withdraw still finds its
    // own earmark + denomination intact and no broadcaster can sweep the pool.
    reserveToncoinsOnBalance(
        contract.getOriginalBalance() - valueCoins - RELAYER_REIMBURSEMENT - recipientAmount +
        rentGrowth,
        RESERVE_MODE_AT_MOST,
    );
    val senderPay = createMessage({
        bounce: false,
        dest: sender,
        value: 0,
    });
    // SAFETY: reserveToncoinsOnBalance pins the pool buffer, every remaining
    // earmark, and every pending native payout before the surplus is carried.
    senderPay.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
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

get fun sparseRoot(domain: uint32, bucketId: uint8): uint256 {
    val storage = lazy TonPoolStorage.load();
    return storage.merkle.load().sparseSetRoot(domain, bucketId);
}

get fun rentRunway(): coins {
    return TonPoolStorage.load().merkle.load().poolRentRunway();
}

get fun relayerReserve(): coins {
    val storage = lazy TonPoolStorage.load();
    return storage.relayerReserve;
}

get fun pendingWithdrawTon(): coins {
    val storage = lazy TonPoolStorage.load();
    return storage.pendingWithdrawTon;
}

get fun withdrawalCount(): uint32 {
    val storage = lazy TonPoolStorage.load();
    val identity = storage.identity.load();
    val deposits = storage.merkle.load().nextIndex;
    return calculateTonPoolWithdrawalCount(
        identity.denomination,
        deposits,
        storage.pendingWithdrawTon,
    );
}

get fun treeDepth(): int {
    return MERKLE_TREE_DEPTH;
}
