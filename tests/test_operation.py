import brownie
from brownie import interface, Contract, accounts
import pytest


def test_operation(
    chain, accounts, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    
    # harvest
    chain.sleep(1)
    strategy.harvest()
    strat = strategy
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # check debt ratio
    debtRatioA = strategy.calcDebtRatioA()
    debtRatioB = strategy.calcDebtRatioB()

    collatRatio = strategy.calcCollateral()
    print('debtRatioA:   {0}'.format(debtRatioA))
    print('debtRatioB:   {0}'.format(debtRatioB))

    print('collatRatio: {0}'.format(collatRatio))
    assert pytest.approx(10000, rel=1e-3) == debtRatioA
    assert pytest.approx(10000, rel=1e-3) == debtRatioB
    assert pytest.approx(6000, rel=1e-2) == collatRatio

    # withdrawal
    percentWithdrawn = 0.5
    vault.withdraw(amount*percentWithdrawn, {"from": user})
    assert (
        pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before - amount*(1-percentWithdrawn)
    )



def test_emergency_exit(
    chain, accounts, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # set emergency and exit
    strategy.setEmergencyExit()
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero
    assert pytest.approx(token.balanceOf(vault), rel=RELATIVE_APPROX) == amount


def test_profitable_harvest(
    chain, accounts, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    before_pps = vault.pricePerShare()

    # Use a whale of the harvest token to send
    harvest = interface.ERC20(conf['harvest_token'])
    harvestWhale = accounts.at(conf['harvest_token_whale'], True)
    sendAmount = round((vault.totalAssets() / conf['harvest_token_price']) * 0.05)
    print('Send amount: {0}'.format(sendAmount))
    print('harvestWhale balance: {0}'.format(harvest.balanceOf(harvestWhale)))
    harvest.transfer(strategy, sendAmount, {'from': harvestWhale})

    # Harvest 2: Realize profit
    chain.sleep(1)
    strategy.harvest()
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    profit = token.balanceOf(vault.address)  # Profits go to vault

    assert strategy.estimatedTotalAssets() + profit > amount
    assert vault.pricePerShare() > before_pps


def test_change_debt(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 50_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    half = int(amount / 2)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    vault.updateStrategyDebtRatio(strategy.address, 50_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero

def test_change_debt_lossy(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # Steal from the strategy
    steal = round(strategy.estimatedTotalAssets() * 0.01)
    strategy.liquidatePositionAuth(steal, {'from': gov})
    token.transfer(user, strategy.balanceOfWant(), {"from": accounts.at(strategy, True)})
    vault.updateStrategyDebtRatio(strategy.address, 50_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=1e-2) == int(amount * 0.98 / 2) 

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero

def test_sweep(gov, vault, strategy, token, user, amount, conf):
    strategy.approveContracts({'from':gov})
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # Protected token doesn't work
    with brownie.reverts("!protected"):
        strategy.sweep(strategy.short(), {"from": gov})
    # with brownie.reverts("!protected"):
    #     strategy.sweep(strategy.wantShortLP(), {"from": gov})
    with brownie.reverts("!protected"):
        strategy.sweep(conf['harvest_token'], {"from": gov})


def test_triggers(
    chain, gov, vault, strategy, token, amount, user, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)


