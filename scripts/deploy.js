require('dotenv').config();
const hre = require('hardhat');

// Mainnet configuration
const MAINNET_CONFIG = {
    XEN_TOKEN: '',
    VRF_COORDINATOR: '',
    KEY_HASH: '',
    SUBSCRIPTION_ID: '', // Replace with actual subscription ID
    CONFIRMATION_BLOCKS: 5,
    MIN_DEPLOYMENT_ETH: '0.01' // Minimum ETH required for deployment
};

async function deployToMainnet(deployer, provider) {
    console.log('\nPreparing Mainnet deployment...');

    // Check minimum balance requirement
    const balance = await provider.getBalance(deployer.address);
    const minimumBalance = ethers.parseEther(MAINNET_CONFIG.MIN_DEPLOYMENT_ETH);
    if (balance < minimumBalance) {
        throw new Error(`Insufficient balance for mainnet deployment. Required: ${MAINNET_CONFIG.MIN_DEPLOYMENT_ETH} ETH`);
    }

    // Get optimal gas price with 20% buffer for mainnet
    const feeData = await provider.getFeeData();
    const gasPrice = (feeData.gasPrice * BigInt(120)) / BigInt(100); // Add 20% buffer
    console.log(`Mainnet gas price (with buffer): ${ethers.formatUnits(gasPrice, 'gwei')} gwei`);

    return {
        xenTokenAddress: MAINNET_CONFIG.XEN_TOKEN,
        vrfCoordinatorAddress: MAINNET_CONFIG.VRF_COORDINATOR,
        keyHash: MAINNET_CONFIG.KEY_HASH,
        subscriptionId: MAINNET_CONFIG.SUBSCRIPTION_ID,
        gasPrice
    };
}

async function main() {
    const { ethers, network } = hre;
    const [deployer] = await ethers.getSigners();
    console.log('Deploying contracts with account:', deployer.address);

    // Get account balance
    const provider = ethers.provider;
    const balance = await provider.getBalance(deployer.address);
    console.log('Account balance:', ethers.formatEther(balance), 'ETH');

    // Initialize variables
    let xenTokenAddress;
    let vrfCoordinatorAddress = process.env.VRF_COORDINATOR_ADDRESS;
    let keyHash = process.env.VRF_KEY_HASH;
    let subscriptionId = process.env.SUBSCRIPTION_ID;
    let platformWallet = process.env.PLATFORM_WALLET || deployer.address;
    let deploymentGasPrice;

    if (network.name === 'mainnet') {
        const mainnetConfig = await deployToMainnet(deployer, provider);
        xenTokenAddress = mainnetConfig.xenTokenAddress;
        vrfCoordinatorAddress = mainnetConfig.vrfCoordinatorAddress;
        keyHash = mainnetConfig.keyHash;
        subscriptionId = mainnetConfig.subscriptionId;
        deploymentGasPrice = mainnetConfig.gasPrice;

        console.log('\nMainnet Configuration:');
        console.log('XEN Token:', xenTokenAddress);
        console.log('VRF Coordinator:', vrfCoordinatorAddress);
        console.log('Key Hash:', keyHash);
        console.log('Subscription ID:', subscriptionId);

        // Additional mainnet safety checks
        const proceed = await confirmMainnetDeployment();
        if (!proceed) {
            console.log('Mainnet deployment cancelled by user');
            process.exit(0);
        }
    } else if (network.name === 'sepolia') {
        xenTokenAddress = process.env.XEN_MOCK_CONTRACT_ADDRESS;
        if (!vrfCoordinatorAddress || !keyHash || !subscriptionId) {
            throw new Error('For Sepolia deployment, please set VRF_COORDINATOR_ADDRESS, VRF_KEY_HASH, and SUBSCRIPTION_ID in your .env file');
        }
    } else if (network.name === 'localhost' || network.name === 'hardhat') {
        const XENTokenMock = await ethers.getContractFactory('XENTokenMock');
        const xenToken = await XENTokenMock.deploy();
        await xenToken.waitForDeployment();
        xenTokenAddress = await xenToken.getAddress();

        const MockVRFCoordinator = await ethers.getContractFactory('MockVRFCoordinatorV2');
        const mockVRFCoordinator = await MockVRFCoordinator.deploy();
        await mockVRFCoordinator.waitForDeployment();
        vrfCoordinatorAddress = await mockVRFCoordinator.getAddress();

        keyHash = '0x' + '0'.repeat(64);
        subscriptionId = '1';
    }

    // Get current network gas price if not already set for mainnet
    if (!deploymentGasPrice) {
        const feeData = await provider.getFeeData();
        deploymentGasPrice = feeData.gasPrice || ethers.parseUnits('20', 'gwei');
    }
    console.log('Deployment gas price:', ethers.formatUnits(deploymentGasPrice, 'gwei'), 'gwei');

    // Deploy Lottery contract
    console.log('\nDeploying Lottery contract...');
    const Lottery = await ethers.getContractFactory('Lottery');
    const lottery = await Lottery.deploy(
        xenTokenAddress,
        platformWallet,
        vrfCoordinatorAddress,
        keyHash,
        subscriptionId,
        {
            gasLimit: 4000000,
            gasPrice: deploymentGasPrice,
        }
    );

    // Wait for deployment
    await lottery.waitForDeployment();

    // Wait for additional confirmations on mainnet
    if (network.name === 'mainnet') {
        const deploymentReceipt = await lottery.deploymentTransaction().wait(MAINNET_CONFIG.CONFIRMATION_BLOCKS);
        console.log(`Deployment confirmed in block: ${deploymentReceipt.blockNumber}`);
    }

    const lotteryAddress = await lottery.getAddress();
    console.log('Lottery deployed to:', lotteryAddress);

    // Get XenNero token address
    const xenNeroTokenAddress = await lottery.xenNeroToken();
    console.log('XenNero Token deployed to:', xenNeroTokenAddress);

    // Save deployment information
    saveDeploymentInfo({
        network: network.name,
        deployer: deployer.address,
        platformWallet,
        xenToken: xenTokenAddress,
        vrfCoordinator: vrfCoordinatorAddress,
        keyHash,
        subscriptionId,
        lottery: lotteryAddress,
        xenNeroToken: xenNeroTokenAddress,
        deploymentTime: new Date().toISOString()
    });

    console.log('\nDeployment Summary:');
    console.log('--------------------');
    console.log('Network:', network.name);
    console.log('Deployer Address:', deployer.address);
    console.log('Platform Wallet:', platformWallet);
    console.log('XEN Token Address:', xenTokenAddress);
    console.log('VRF Coordinator Address:', vrfCoordinatorAddress);
    console.log('Key Hash:', keyHash);
    console.log('Subscription ID:', subscriptionId);
    console.log('Lottery Contract Address:', lotteryAddress);
    console.log('XenNero Token Address:', xenNeroTokenAddress);

    // Verify contracts on supported networks
    if (["mainnet", "goerli", "sepolia"].includes(network.name)) {
        console.log("\nStarting contract verification...");
        try {
            // Wait longer for mainnet
            const verificationDelay = network.name === 'mainnet' ? 60000 : 30000;
            await new Promise(resolve => setTimeout(resolve, verificationDelay));

            // Verify Lottery contract
            await hre.run("verify:verify", {
                address: lotteryAddress,
                constructorArguments: [
                    xenTokenAddress,
                    platformWallet,
                    vrfCoordinatorAddress,
                    keyHash,
                    subscriptionId
                ],
            });

            // Verify XenNero token contract
            await hre.run("verify:verify", {
                address: xenNeroTokenAddress,
                constructorArguments: [lotteryAddress],
            });

            console.log("Contract verification completed successfully");
        } catch (error) {
            console.error("Contract verification failed:", error);
            console.log("\nManual Verification Information:");
            console.log("Lottery Contract:");
            console.log("Address:", lotteryAddress);
            console.log("Constructor Arguments:", [
                xenTokenAddress,
                platformWallet,
                vrfCoordinatorAddress,
                keyHash,
                subscriptionId
            ]);
            console.log("\nXenNero Token Contract:");
            console.log("Address:", xenNeroTokenAddress);
            console.log("Constructor Arguments:", [lotteryAddress]);
        }
    }

    console.log("\nDeployment process completed!");
}

// Helper function to save deployment information
function saveDeploymentInfo(deploymentInfo) {
    const fs = require('fs');
    const deploymentPath = `./deployments/${deploymentInfo.network}`;
    if (!fs.existsSync(deploymentPath)) {
        fs.mkdirSync(deploymentPath, { recursive: true });
    }
    fs.writeFileSync(
        `${deploymentPath}/deployment-${Date.now()}.json`,
        JSON.stringify(deploymentInfo, null, 2)
    );
    console.log(`Deployment information saved to ${deploymentPath}`);
}

// Helper function to confirm mainnet deployment
async function confirmMainnetDeployment() {
    const readline = require('readline').createInterface({
        input: process.stdin,
        output: process.stdout
    });

    return new Promise((resolve) => {
        readline.question('\n⚠️  WARNING: You are about to deploy to Ethereum Mainnet. Type "CONFIRM" to proceed: ', (answer) => {
            readline.close();
            resolve(answer === 'CONFIRM');
        });
    });
}

// Error handling wrapper
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Error during deployment:', error);
        process.exit(1);
    });