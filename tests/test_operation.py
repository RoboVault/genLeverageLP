import brownie
from brownie import interface, Contract, accounts
import pytest
import time

def steal(stealPercent, strategy, token, chain, gov, user):
    steal = round(strategy.estimatedTotalAssets() * stealPercent)
    strategy.liquidatePositionAuth(steal, {'from': gov})
    token.transfer(user, strategy.balanceOfWant(), {"from": accounts.at(strategy, True)})
    chain.sleep(1)
    chain.mine(1)

def strategySharePrice(strategy, vault):
    return strategy.estimatedTotalAssets() / vault.strategies(strategy)['totalDebt']


#CASE A = both debt ratios are less than 100%

def test_operation_nomral(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, conf
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

    chain.sleep(1)
    chain.mine(1)

    # check debt ratio
    debtRatioA = strategy.calcDebtRatioA()
    debtRatioB = strategy.calcDebtRatioB()

    collatRatio = strategy.calcCollateral()
    print('debtRatioA:   {0}'.format(debtRatioA))
    print('debtRatioB:   {0}'.format(debtRatioB))
    print('collatRatio: {0}'.format(collatRatio))
    #assert pytest.approx(10000, rel=1e-3) == debtRatioA
    #assert pytest.approx(10000, rel=1e-3) == debtRatioB
    assert pytest.approx(strategy.collatTarget(), rel=1e-2) == collatRatio

    # withdrawal
    vault.withdraw(amount, {"from": user})
    assert (
        pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before
    )

def test_operation_lossy(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, conf
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

    chain.sleep(1)
    chain.mine(1)
    
    # check debt ratio
    debtRatioA = strategy.calcDebtRatioA()
    debtRatioB = strategy.calcDebtRatioB()

    collatRatio = strategy.calcCollateral()
    print('debtRatioA:   {0}'.format(debtRatioA))
    print('debtRatioB:   {0}'.format(debtRatioB))
    print('collatRatio: {0}'.format(collatRatio))
    #assert pytest.approx(10000, rel=1e-3) == debtRatioA
    #assert pytest.approx(10000, rel=1e-3) == debtRatioB
    assert pytest.approx(strategy.collatTarget(), rel=1e-2) == collatRatio

    # withdrawal
    vault.withdraw(amount, {"from": user})
    assert (
        pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before
    )


def test_operation_case_A(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, conf
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

    tradingFeeWhale = '0xd061c6586670792331E14a80f3b3Bb267189C681'
    shortA = Contract(strategy.shortA())
    shortB = Contract(strategy.shortB())
    sendAmtA = shortA.balanceOf(lp_token)*0.002
    sendAmtB = shortB.balanceOf(lp_token)*0.002

    shortA.transfer(lp_token, sendAmtA, {'from': tradingFeeWhale})
    shortB.transfer(lp_token, sendAmtB, {'from': tradingFeeWhale})

    spookyRouter = Contract("0xF491e7B69E4244ad4002BC14e878a34207E38c29")

    shortA.approve(spookyRouter, 2**256-1, {"from": tradingFeeWhale})
    swapAmt = sendAmtA*0.01 
    # do tiny trade as this should make sure reserves are updated 
    spookyRouter.swapExactTokensForTokens(swapAmt, 0, [shortA, shortB], tradingFeeWhale, 2**256-1, {"from": tradingFeeWhale})

    chain.sleep(1)
    chain.mine(1)

    # check debt ratio
    debtRatioA = strategy.calcDebtRatioA()
    debtRatioB = strategy.calcDebtRatioB()

    collatRatio = strategy.calcCollateral()
    print('debtRatioA:   {0}'.format(debtRatioA))
    print('debtRatioB:   {0}'.format(debtRatioB))
    print('collatRatio: {0}'.format(collatRatio))
    #assert pytest.approx(10000, rel=1e-3) == debtRatioA
    #assert pytest.approx(10000, rel=1e-3) == debtRatioB
    assert pytest.approx(strategy.collatTarget(), rel=1e-2) == collatRatio

    # withdrawal
    vault.withdraw(amount, {"from": user})
    assert (
        pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before
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


def test_reduce_debt(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    half = int(amount / 2)

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
    # Deposit to the vault and harvest
    strategy.approveContracts({'from':gov})
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})


    chain.sleep(1)
    strategy.harvest()

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
        strategy.sweep(strategy.shortA(), {"from": gov})

    with brownie.reverts("!protected"):
        strategy.sweep(strategy.shortB(), {"from": gov})

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


def test_lossy_withdrawal(
    chain, gov, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    # Deposit to the vault and harvest
    strategy.approveContracts({'from':gov})

    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # Steal from the strategy
    stealPercent = 0.01
    steal(stealPercent, strategy, token, chain, gov, user)

    chain.mine(1)
    balBefore = token.balanceOf(user)
    vault.withdraw(amount, user, 150, {'from' : user}) 
    balAfter = token.balanceOf(user)
    assert pytest.approx(balAfter - balBefore, rel = 2e-3) == int(amount * .99)

def test_lossy_withdrawal_partial(
    chain, gov, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    # Deposit to the vault and harvest
    strategy.approveContracts({'from':gov})

    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount


    # Steal from the strategy
    stealPercent = 0.005
    steal(stealPercent, strategy, token, chain, gov, user)

    balBefore = token.balanceOf(user)
    ssp_before = strategySharePrice(strategy, vault)

    #give RPC a little break to stop it spzzing out 
    time.sleep(5)

    half = int(amount / 2)
    vault.withdraw(half, user, 100, {'from' : user}) 
    balAfter = token.balanceOf(user)
    assert pytest.approx(balAfter - balBefore, rel = 2e-3) == (half * (1-stealPercent)) 

    # Check the strategy share price wasn't negatively effected
    ssp_after = strategySharePrice(strategy, vault)
    assert pytest.approx(ssp_before, rel = 2e-5) == ssp_after

def test_lossy_withdrawal_tiny(
    chain, gov, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    # Deposit to the vault and harvest
    strategy.approveContracts({'from':gov})

    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})


    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount


    # Steal from the strategy
    stealPercent = 0.005
    steal(stealPercent, strategy, token, chain, gov, user)
    
    balBefore = token.balanceOf(user)
    ssp_before = strategySharePrice(strategy, vault)

    #give RPC a little break to stop it spzzing out 
    time.sleep(5)

    tiny = int(amount * 0.001)
    vault.withdraw(tiny, user, 100, {'from' : user}) 
    balAfter = token.balanceOf(user)
    assert pytest.approx(balAfter - balBefore, rel = 2e-3) == (tiny * (1-stealPercent)) 

    # Check the strategy share price wasn't negatively effected
    ssp_after = strategySharePrice(strategy, vault)
    assert pytest.approx(ssp_before, rel = 2e-5) == ssp_after

def test_lossy_withdrawal_99pc(
    chain, gov, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    # Deposit to the vault and harvest

    strategy.approveContracts({'from':gov})


    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # Steal from the strategy
    stealPercent = 0.005
    steal(stealPercent, strategy, token, chain, gov, user)

    balBefore = token.balanceOf(user)
    ssp_before = strategySharePrice(strategy, vault)

    #give RPC a little break to stop it spzzing out 
    time.sleep(5)

    tiny = int(amount * 0.99)
    vault.withdraw(tiny, user, 100, {'from' : user}) 
    balAfter = token.balanceOf(user)
    assert pytest.approx(balAfter - balBefore, rel = 2e-3) == (tiny * (1-stealPercent)) 

    # Check the strategy share price wasn't negatively effected
    ssp_after = strategySharePrice(strategy, vault)
    assert pytest.approx(ssp_before, rel = 2e-5) == ssp_after

def test_lossy_withdrawal_95pc(
    chain, gov, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    # Deposit to the vault and harvest

    strategy.approveContracts({'from':gov})


    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount


    # Steal from the strategy
    stealPercent = 0.005
    steal(stealPercent, strategy, token, chain, gov, user)

    balBefore = token.balanceOf(user)
    ssp_before = strategySharePrice(strategy, vault)

    #give RPC a little break to stop it spzzing out 
    time.sleep(5)

    tiny = int(amount * 0.95)
    vault.withdraw(tiny, user, 100, {'from' : user}) 
    balAfter = token.balanceOf(user)
    assert pytest.approx(balAfter - balBefore, rel = 2e-3) == (tiny * (1-stealPercent)) 

    # Check the strategy share price wasn't negatively effected
    ssp_after = strategySharePrice(strategy, vault)
    assert pytest.approx(ssp_before, rel = 2e-5) == ssp_after
