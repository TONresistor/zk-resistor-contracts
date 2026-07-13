import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/testing/assert"
import "@contracts/factory-types"
import "@wrappers/Factory.gen"

const FACTORY_ADDRESS_HASH: uint256 = 0x7c5b55b6efa196890a4af3c4b1e3a2b6d2bb0cac22887b33a9c05189e1d8635b

fun initialFactoryStorage(): FactoryStorage {
    val registries: Registries = { poolRegistry: [], tonPoolRegistry: [] };
    val createSenders: CreateSenders = { poolAddressToCreator: [], tonPoolAddressToCreator: [] };

    return {
        codes: (FactoryCodes {
            poolCode: build("Pool"),
            tonPoolCode: build("TonPool"),
        }).toCell(),
        poolCount: 0,
        tonPoolCount: 0,
        inFlightCreates: 0,
        registries: registries.toCell(),
        createSenders: createSenders.toCell(),
    };
}

fun main() {
    val deployer = scripts.wallet("deployer");
    val expectedAddress = address.fromWorkchainAndHash(BASECHAIN, FACTORY_ADDRESS_HASH);
    val factory = Factory.fromStorage(initialFactoryStorage());

    if (factory.address != expectedAddress) {
        Assert.fail("Factory StateInit does not match the pinned canonical address");
    }

    println("Factory address: {}", factory.address);
    println("Deployer: {}", deployer.address);

    if (scripts.isContractDeployed(factory.address)) {
        println("Factory is already deployed");
        return;
    }

    val result = factory.deploy(deployer.address, { value: ton("0.5") });
    val applied = result.waitForFirstTransaction();
    if (applied == null) {
        Assert.fail("Factory deployment was not observed on-chain");
    }

    println("Factory deployed: {}", factory.address);
}
