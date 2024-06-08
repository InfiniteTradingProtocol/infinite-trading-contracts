import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const ItpStakingV1 = buildModule("ItpStakingV1", (m) => {
    const initialOwner = m.getParameter("initialOwner");
    const token = m.getParameter("token");
    const lockTimeDuration = m.getParameter("lockTimeDuration");
    const initialRewardsRatePerLockMultiplierBps = m.getParameter("initialRewardsRatePerLockMultiplierBps");

    const iptStakingV1 = m.contract("ItpStakingV1",
        [initialOwner, token, lockTimeDuration, initialRewardsRatePerLockMultiplierBps]
    );

    return { iptStakingV1 };
});

export default ItpStakingV1;