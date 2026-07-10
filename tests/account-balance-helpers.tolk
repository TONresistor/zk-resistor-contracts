import "@acton/emulation/testing"
import "@acton/types/transaction"

// Set an exact pre-message balance without relying on deployment-fee timing.
// Synchronizing lastPaid with the frozen emulator time makes one-nanoton
// boundary tests deterministic under coverage and on slower CI runners.
fun setExactTestAccountBalance(addr: address, balance: coins): void {
    var now = testing.getNow();
    if (now == 0) {
        // Zero is Acton's sentinel for wall-clock fallback, not a frozen time.
        now = blockchain.now();
    }
    testing.setNow(now);
    val currentShard = testing.getShardAccount(addr);
    assert (currentShard != null) throw 9905;
    var shard = currentShard!;
    val currentAccount = shard.account.load();
    assert (currentAccount is TlbAccountInfo) throw 9905;
    var account = currentAccount;
    account.storage.balance.grams = balance;
    account.storageStat.lastPaid = now;
    shard.account = (account as TlbAccount).toCell();
    testing.setShardAccount(addr, shard);
}
