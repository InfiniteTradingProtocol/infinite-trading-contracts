import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import hre from "hardhat";
import { Token__factory } from "../typechain-types";
import { bigint } from "hardhat/internal/core/params/argumentTypes";

function calculatePenalty(
  amount: number,
  initialLockTime: number,
  unlockTime: number,
  currentTime: number
): number {
  if (currentTime >= unlockTime) {
    return 0;
  }

  if (initialLockTime >= unlockTime) {
    return 0;
  }

  const unlockDelta = (unlockTime - currentTime) / (unlockTime - initialLockTime);

  console.log("T: Unlock delta: ", unlockDelta);

  const penaltyRateBps = 2000;

  return (amount * unlockDelta * penaltyRateBps) / 10000;
}

describe("ItpStakingV1", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployFixture() {
    const ONE_YEAR_IN_SECS = 365 * 24 * 60 * 60;
    const REWARDS_AMOUNT = 10_000_000;
    const STAKER_INITIAL_BALANCE = 30_000_000;

    // Contracts are deployed using the first signer/account by default
    const [owner, otherAccount] = await hre.ethers.getSigners();

    const Token = await hre.ethers.getContractFactory("Token");
    const ItpStakingV1 = await hre.ethers.getContractFactory("ItpStakingV1");

    const token = await Token.deploy();
    const stakingVault = await ItpStakingV1.deploy(owner.address, token.getAddress(), ONE_YEAR_IN_SECS, [1500, 2000, 2500, 3000]);

    // Setup initial conditions

    // Give some tokens to other account
    await token.connect(owner).transfer(otherAccount, hre.ethers.parseEther(STAKER_INITIAL_BALANCE.toString()));

    // Transfer initial rewards to vault
    await token.connect(owner).approve(stakingVault, hre.ethers.parseEther(REWARDS_AMOUNT.toString()));
    await stakingVault.connect(owner).depositRewards(hre.ethers.parseEther(REWARDS_AMOUNT.toString()));


    console.log("Rewards Amount");
    console.log(hre.ethers.parseEther(REWARDS_AMOUNT.toString()));

    console.log("Deposit Amount");
    console.log(hre.ethers.parseEther("100000"));

    // Approve vault to spend otherAccount
    await token.connect(otherAccount).approve(stakingVault, hre.ethers.parseEther(STAKER_INITIAL_BALANCE.toString()));

    return { token, stakingVault, owner, otherAccount, REWARDS_AMOUNT };
  }

  describe("Deploy", function () {
    it("Should have initial amount of rewards", async function () {
      const { token, stakingVault, owner, otherAccount, REWARDS_AMOUNT } = await loadFixture(deployFixture);

      const initialTokenAmount = await token.balanceOf(stakingVault);
      const initialRewardsAmount = await stakingVault.rewardsLeft();

      expect(initialTokenAmount).to.equal(hre.ethers.parseEther(REWARDS_AMOUNT.toString()));
      expect(initialTokenAmount).to.equal(initialRewardsAmount);
    });
  });

  describe("Deposit", function () {
    it("Should deposit and stake info amounts should match the account's balance", async function () {
      const { token, stakingVault, owner, otherAccount } = await loadFixture(deployFixture);

      const makeADeposit = await stakingVault.connect(otherAccount).deposit(hre.ethers.parseEther("100"), "1");
      const stakedInfo = await stakingVault.getStakeInfo(otherAccount);

      console.log(stakedInfo);
      const now = await time.latest();
      console.log(now);

      const totalStaked = await stakingVault.totalStaked();
      var depositAndReward = BigInt(0);
      for (var i = 0; i < stakedInfo.length; i++) {
        depositAndReward += stakedInfo[i].depositAmount + stakedInfo[i].rewardsAmount;
      }

      console.log("Deposit + Reward: ", depositAndReward);

      const balanceOfStaker = await stakingVault.stakedBalanceOf(otherAccount);

      console.log("Balance of: ", balanceOfStaker);

      await Promise.all([
        expect(balanceOfStaker).to.equal(totalStaked),
        expect(depositAndReward).to.equal(totalStaked),
        expect(depositAndReward).to.equal(balanceOfStaker),
      ]);

    });
    it("Should deposit with invalid lock multiplier and revert", async function () {
      const { token, stakingVault, owner, otherAccount } = await loadFixture(deployFixture);

      await Promise.all([
        expect(stakingVault.connect(otherAccount).deposit(hre.ethers.parseEther("100"), 0)).to.be.revertedWithCustomError(
          stakingVault,
          "InvalidLockMultiplier"
        ),
        expect(stakingVault.connect(otherAccount).deposit(hre.ethers.parseEther("100"), 5)).to.be.revertedWithCustomError(
          stakingVault,
          "InvalidLockMultiplier"
        ),
      ]);

    });
  });

  describe("Withdraw", function () {
    it("Should deposit with 1 year lock and withdraw with valid unlock time", async function () {
      const { token, stakingVault, owner, otherAccount, REWARDS_AMOUNT } = await loadFixture(deployFixture);

      const makeAdeposit = await stakingVault.connect(otherAccount).deposit(hre.ethers.parseEther("100"), "1");
      await time.increase(365 * 24 * 60 * 60);

      await stakingVault.connect(otherAccount).withdraw([
        1
      ]);

      console.log("After Withdraw");
      const wStakedInfo = await stakingVault.getStakeInfo(otherAccount);
      console.log(wStakedInfo);

      const totalStakedAfterWithdraw = await stakingVault.totalStaked();
      const rewardsLeftAfterWithdraw = await stakingVault.rewardsLeft();
      const expectedRewardsLeft = hre.ethers.parseEther((REWARDS_AMOUNT - 100 * 1500 / 10000).toString());

      await Promise.all([
        expect(totalStakedAfterWithdraw).to.equal(0),
        expect(rewardsLeftAfterWithdraw).equal(expectedRewardsLeft),
      ]);
    });
  });

  describe("Extend Lock", function () {
    it("Should Extend lock by 2 years and update the rewards", async function () {
      const { token, stakingVault, owner, otherAccount, REWARDS_AMOUNT } = await loadFixture(deployFixture);

      const makeAdeposit = await stakingVault.connect(otherAccount).deposit(hre.ethers.parseEther("100"), "1");

      await stakingVault.connect(otherAccount).extendLock("1", "2");

      // one year at 15, then extend 2 years at 20: 15 + 23 + 27.6 should be the rewards sum

      console.log("After Extending lock for first entry");

      const stakedInfo = await stakingVault.getStakeInfo(otherAccount);
      console.log(stakedInfo);


      const balanceOfStaker = await stakingVault.stakedBalanceOf(otherAccount);
      console.log("Balance of: ", balanceOfStaker);

      await Promise.all([
        expect(balanceOfStaker).to.equal(stakedInfo[0].depositAmount + stakedInfo[0].rewardsAmount),
      ]);
    });
  });

  describe("Early Withdraw", function () {
    it("Should deposit and early withdraw immediately with penalty", async function () {
      const { token, stakingVault, owner, otherAccount, REWARDS_AMOUNT } = await loadFixture(deployFixture);

      const oneYearInSeconds = 365 * 24 * 60 * 60;
      const timestamp = await time.latest();

      const makeAdeposit = await stakingVault.connect(otherAccount).deposit(hre.ethers.parseEther("100"), "1");
      const stakeInfoBeforeEw = await stakingVault.getStakeInfo(otherAccount);

      //await time.increaseTo(timestamp + (365 / 2) * (24 * 60 * 60));
      const increasedTime = await time.latest();
      const expectedPenalty = calculatePenalty(100, timestamp, timestamp + oneYearInSeconds, increasedTime);

      console.log("T: Expected Penalty: ", expectedPenalty);

      const rewardsLeftBeforeEw = await stakingVault.connect(otherAccount).rewardsLeft();
      console.log("Before EW rewardsLeft: ", rewardsLeftBeforeEw);

      const earlyWithdrawEventResult = await stakingVault.connect(otherAccount).earlyWithdraw("1");

      // Rewards sould go back to the vault's rewards
      const rewardsLeftAfterEw = await stakingVault.connect(otherAccount).rewardsLeft();
      console.log("After EW rewardsLeft: ", rewardsLeftAfterEw);

      console.log("After Early withdraw for first entry");

      const stakedInfo = await stakingVault.getStakeInfo(otherAccount);
      console.log(stakedInfo);


      const totalPenalty = await stakingVault.connect(otherAccount).totalPenalty();
      console.log("Total Penalty: " + hre.ethers.formatEther(totalPenalty));

      await Promise.all([
        expect(rewardsLeftAfterEw).equal(rewardsLeftBeforeEw + stakeInfoBeforeEw[0].rewardsAmount),
        expect(Math.floor(expectedPenalty * 100) / 100).to.equal(Number(hre.ethers.formatEther(totalPenalty))),
      ]);
    });
  });

  describe("Owner", function () {
    it("Should burn penalty", async function () {
      const { token, stakingVault, owner, otherAccount, REWARDS_AMOUNT } = await loadFixture(deployFixture);

      const oneYearInSeconds = 365 * 24 * 60 * 60;
      const timestamp = await time.latest();

      const makeAdeposit = await stakingVault.connect(otherAccount).deposit(hre.ethers.parseEther("100"), "1");

      //await time.increaseTo(timestamp + (365 / 2) * (24 * 60 * 60));
      const increasedTime = await time.latest();
      const expectedPenalty = calculatePenalty(100, timestamp, timestamp + oneYearInSeconds, increasedTime);

      console.log("T: Expected Penalty: ", expectedPenalty);

      const rewardsLeftBeforeEw = await stakingVault.connect(otherAccount).rewardsLeft();
      console.log("Before EW rewardsLeft: ", rewardsLeftBeforeEw);

      const earlyWithdrawEventResult = await stakingVault.connect(otherAccount).earlyWithdraw("1");

      const totalPenalty = await stakingVault.connect(otherAccount).totalPenalty();
      console.log("Total Penalty: " + hre.ethers.formatEther(totalPenalty));

      // Burn test
      const vaultBalanceBeforeBurn = await token.balanceOf(stakingVault);
      console.log("Vault Balance before burn: " + hre.ethers.formatEther(vaultBalanceBeforeBurn));

      await stakingVault.connect(owner).burnPenalty(totalPenalty);

      const afterBurnTotalPenalty = await stakingVault.connect(otherAccount).totalPenalty();
      const afterBurnTotalBurned = await stakingVault.connect(otherAccount).totalPenaltyBurned();

      const vaultBalanceAfterBurn = await token.balanceOf(stakingVault);
      console.log("Vault Balance after burn: " + hre.ethers.formatEther(vaultBalanceAfterBurn));


      console.log("After burn Total Penalty: " + hre.ethers.formatEther(afterBurnTotalPenalty));
      console.log("After burn Total burned: " + hre.ethers.formatEther(afterBurnTotalBurned));

      await Promise.all([
        expect(totalPenalty).to.equal(afterBurnTotalBurned),
        expect(afterBurnTotalPenalty).to.equal(0)
      ]);
    });
  });

  it("Should setRewardsRatePerLockMultiplierBps", async function () {
    const { token, stakingVault, owner, otherAccount, REWARDS_AMOUNT } = await loadFixture(deployFixture);

    const newRates: bigint[] = [1000n, 2000n, 3000n, 4000n];
    await stakingVault.connect(owner).setRewardsRatePerLockMultiplierBps(newRates);

    const vaultNewRate = await stakingVault.getRewardsRatePerLockMultiplierBps();

    expect(newRates.toString()).to.be.equal(vaultNewRate.toString());
  });
});
