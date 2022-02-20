import brownie
from brownie import Contract, interface, accounts
import pytest


def farmWithdraw(lp_farm, pid, strategy, amount):
    auth = accounts.at(strategy, True)
    if (lp_farm.address == '0x6e2ad6527901c9664f016466b8DA1357a004db0f'):
        lp_farm.withdraw(pid, amount, strategy, {'from': auth}) 
    else:
        lp_farm.withdraw(pid, amount, {'from': auth})

@pytest.fixture
def short(strategy):
    assert Contract(strategy.short())


def test_collat_rebalance(chain, accounts, token, deployed_vault, strategy, user, conf, gov, lp_token, lp_whale, lp_farm, lp_price, pid):

    # set high collateral and rebalance
    target = 6000
    strategy.setCollateralThresholds(target-500, target, target+500)

    # rebalance
    strategy.rebalanceCollateral()
    debtCollat = strategy.calcCollateral()
    print('CollatRatio: {0}'.format(debtCollat))
    assert pytest.approx(target, rel=1e-2) == debtCollat

    # set low collateral and rebalance
    target = 2000
    strategy.setCollateralThresholds(target-500, target, target+500)

    # rebalance
    strategy.rebalanceCollateral()
    debtCollat = strategy.calcCollateral()
    print('CollatRatio: {0}'.format(debtCollat))
    assert pytest.approx(target, rel=1e-2) == debtCollat



def test_set_collat_thresholds(chain, accounts, token, deployed_vault, strategy, user, conf, gov, lp_token, lp_whale, lp_farm, lp_price, pid):
    # Vault share token doesn't work
    with brownie.reverts():
        strategy.setCollateralThresholds(5000, 4000, 6000)

    strategy.setCollateralThresholds(2000, 2500, 3000)

