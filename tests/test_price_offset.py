import brownie
from brownie import Contract, interface, accounts
import pytest
import time 

# PUT ALL TESTS HERE WHERE WE OFFSET THE LP PRICE 

#this gets LP on other AMM so we can SIM a swap to offset debt Ratios 
def getWhaleAddress(strategy, routerAddress, Contract) : 
    spiritRouter = '0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52'
    spookyRouter = '0xF491e7B69E4244ad4002BC14e878a34207E38c29'
    if (routerAddress == spiritRouter):
        altRouter = spookyRouter
    else : altRouter = spiritRouter

    altRouterContract = Contract(altRouter)
    factory = Contract(altRouterContract.factory())
    token = strategy.shortA()
    short = strategy.shortB()

    whale = factory.getPair(token, short)

    return(whale)


def offSetDebtRatioA(strategy, lp_token, token, Contract, swapPct, router):
    # use other AMM's LP to force some swaps 
    whale = getWhaleAddress(strategy, lp_token, Contract)
    shortA = Contract(strategy.shortA())
    shortB = Contract(strategy.shortB())
    swapAmtMax = shortA.balanceOf(lp_token)*swapPct
    swapAmt = min(swapAmtMax, shortA.balanceOf(whale))
    print("Force Large Swap - to offset debt ratios")
    shortA.approve(router, 2**256-1, {"from": whale})
    router.swapExactTokensForTokens(swapAmt, 0, [shortA, shortB], whale, 2**256-1, {"from": whale})


def offSetDebtRatioB(strategy, lp_token, token, Contract, swapPct, router):
    # use other AMM's LP to force some swaps 
    whale = getWhaleAddress(strategy, lp_token, Contract)
    shortA = Contract(strategy.shortA())
    shortB = Contract(strategy.shortB())
    swapAmtMax = shortB.balanceOf(lp_token)*swapPct
    swapAmt = min(swapAmtMax, shortB.balanceOf(whale))
    print("Force Large Swap - to offset debt ratios")
    shortB.approve(router, 2**256-1, {"from": whale})
    router.swapExactTokensForTokens(swapAmt, 0, [shortB, shortA], whale, 2**256-1, {"from": whale})


def test_debt_rebalance_low(chain, accounts, token, deployed_vault, strategy, user, conf, gov, lp_token, router, Contract):
    ###################################################################
    # Test Debt Rebalance
    ###################################################################
    # Change the debt ratio to ~95% and rebalance

    # USE SPIRIT LP 
    swapPct = 0.025

    offSetDebtRatioA(strategy, lp_token, token, Contract, swapPct, router)

    print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
    print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))

    print("Complete Rebalance")

    # Rebalance Debt  and check it's back to the target
    strategy.rebalanceDebt()
    print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
    print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))

    assert pytest.approx(10000, rel=1e-2) == strategy.calcDebtRatioA()
    assert pytest.approx(10000, rel=1e-2) == strategy.calcDebtRatioB()

def test_debt_rebalance_high(chain, accounts, token, deployed_vault, strategy, user, conf, gov, lp_token, router, Contract):
    ###################################################################
    # Test Debt Rebalance
    ###################################################################
    # Change the debt ratio to ~95% and rebalance

    # USE SPIRIT LP 
    swapPct = 0.025

    offSetDebtRatioB(strategy, lp_token, token, Contract, swapPct, router)

    print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
    print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))

    print("Complete Rebalance")

    # Rebalance Debt  and check it's back to the target
    strategy.rebalanceDebt()
    print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
    print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))

    assert pytest.approx(10000, rel=1e-2) == strategy.calcDebtRatioA()
    assert pytest.approx(10000, rel=1e-2) == strategy.calcDebtRatioB()


def test_operation_OffsetA(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, router, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    
    # harvest
    chain.sleep(1)
    strategy.harvest()
    strat = strategy
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    swapPct = 0.01
    offSetDebtRatioA(strategy, lp_token, token, Contract, swapPct, router)

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

    user_balance_before = token.balanceOf(user)
    loss_adj = strategy.estimatedTotalAssets() / amount 

    # withdrawal
    vault.withdraw(amount, user, 500, {"from": user})
    assert (
        pytest.approx(token.balanceOf(user), rel=1e-2) == user_balance_before + amount*loss_adj
    )

def test_operation_OffsetB(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, router, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    
    # harvest
    chain.sleep(1)
    strategy.harvest()
    strat = strategy
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    swapPct = 0.01
    offSetDebtRatioB(strategy, lp_token, token, Contract, swapPct, router)

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

    user_balance_before = token.balanceOf(user)
    loss_adj = strategy.estimatedTotalAssets() / amount 

    # withdrawal
    vault.withdraw(amount, user, 500, {"from": user})
    assert (
        pytest.approx(token.balanceOf(user), rel=1e-2) == user_balance_before + amount*loss_adj
    )


def test_reduce_debt_offsetA(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, router, lp_token , Contract, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    half = int(amount / 2)

    swapPct = 0.02
    offSetDebtRatioA(strategy, lp_token, token, Contract, swapPct, router)

    
    vault.updateStrategyDebtRatio(strategy.address, 50_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero



def test_reduce_debt_offsetB(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, router, lp_token , Contract, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    half = int(amount / 2)

    swapPct = 0.02
    offSetDebtRatioB(strategy, lp_token, token, Contract, swapPct, router)

    vault.updateStrategyDebtRatio(strategy.address, 50_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero

def test_increase_debt_offsetA(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, router, lp_token , Contract, conf
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

    swapPct = 0.02
    offSetDebtRatioA(strategy, lp_token, token, Contract, swapPct, router)

    lossAdj = strategy.estimatedTotalAssets() / half

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half*(1 + lossAdj)


def test_increase_debt_offsetB(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, router, lp_token , Contract, conf
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

    swapPct = 0.02
    offSetDebtRatioB(strategy, lp_token, token, Contract, swapPct, router)

    lossAdj = strategy.estimatedTotalAssets() / half

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half*(1 + lossAdj)



def test_partialWithdraw_OffsetA(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, router, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    
    # harvest
    chain.sleep(1)
    strategy.harvest()
    strat = strategy
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    swapPct = 0.02
    offSetDebtRatioA(strategy, lp_token, token, Contract, swapPct, router)


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

    withdrawPct = 0.5
    withdrawAmt = int(amount*withdrawPct)

    # check impact of offseting debt ratios on assets 
    lossAdj = strategy.estimatedTotalAssets() / amount 

    user_balance_before = token.balanceOf(user)

    vault.withdraw(withdrawAmt, user, 500, {'from' : user}) 

    assert (
        pytest.approx(token.balanceOf(user), rel=2e-3) == user_balance_before + withdrawPct*lossAdj*amount
    )

    assert( 
        pytest.approx(strategy.estimatedTotalAssets(), rel = 2e-3) == amount*(1-withdrawPct)*lossAdj
    )

    print("Post Withdrawal")

    debtRatioANew = strategy.calcDebtRatioA()
    debtRatioBNew = strategy.calcDebtRatioB()

    print('debtRatioA:   {0}'.format(debtRatioANew))
    print('debtRatioB:   {0}'.format(debtRatioBNew))

    assert (
        pytest.approx(debtRatioANew, rel=2e-3) == debtRatioA
    )

    assert (
        pytest.approx(debtRatioBNew, rel=2e-3) == debtRatioB
    )

def test_partialWithdraw_OffsetB(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, router, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    
    # harvest
    chain.sleep(1)
    strategy.harvest()
    strat = strategy
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    swapPct = 0.02
    offSetDebtRatioB(strategy, lp_token, token, Contract, swapPct, router)

    chain.sleep(1)
    chain.mine(1)

    # check debt ratio
    debtRatioA = strategy.calcDebtRatioA()
    debtRatioB = strategy.calcDebtRatioB()

    collatRatio = strategy.calcCollateral()
    print('debtRatioA:   {0}'.format(debtRatioA))
    print('debtRatioB:   {0}'.format(debtRatioB))
    print('collatRatio: {0}'.format(collatRatio))

    assert pytest.approx(strategy.collatTarget(), rel=1e-2) == collatRatio

    withdrawPct = 0.5
    withdrawAmt = int(amount*withdrawPct)

    # check impact of offseting debt ratios on assets 
    lossAdj = strategy.estimatedTotalAssets() / amount 
    user_balance_before = token.balanceOf(user)
    vault.withdraw(withdrawAmt, user, 500, {'from' : user}) 

    assert (
        pytest.approx(token.balanceOf(user), rel=2e-3) == user_balance_before + withdrawPct*lossAdj*amount
    )
    assert( 
        pytest.approx(strategy.estimatedTotalAssets(), rel = 2e-3) == amount*(1-withdrawPct)*lossAdj
    )

    print("Post Withdrawal")
    debtRatioANew = strategy.calcDebtRatioA()
    debtRatioBNew = strategy.calcDebtRatioB()
    print('debtRatioA:   {0}'.format(debtRatioANew))
    print('debtRatioB:   {0}'.format(debtRatioBNew))
    assert (
        pytest.approx(debtRatioANew, rel=2e-3) == debtRatioA
    )
    assert (
        pytest.approx(debtRatioBNew, rel=2e-3) == debtRatioB
    )


def test_fullWithdraw_OffsetA(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, router, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    
    # harvest
    chain.sleep(1)
    strategy.harvest()
    strat = strategy
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    swapPct = 0.02
    offSetDebtRatioA(strategy, lp_token, token, Contract, swapPct, router)

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

    withdrawPct = 1
    withdrawAmt = int(amount*withdrawPct)

    # check impact of offseting debt ratios on assets 
    lossAdj = strategy.estimatedTotalAssets() / amount 

    user_balance_before = token.balanceOf(user)

    vault.withdraw(withdrawAmt, user, 500, {'from' : user}) 

    assert (
        pytest.approx(token.balanceOf(user), rel=1e-2) == user_balance_before + withdrawPct*lossAdj*amount
    )

    assert( 
        pytest.approx(strategy.estimatedTotalAssets(), rel = 2e-3) == amount*(1-withdrawPct)*lossAdj
    )


def test_fullWithdraw_OffsetB(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, router, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    
    # harvest
    chain.sleep(1)
    strategy.harvest()
    strat = strategy
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    swapPct = 0.02
    offSetDebtRatioB(strategy, lp_token, token, Contract, swapPct, router)

    chain.sleep(1)
    chain.mine(1)

    # check debt ratio
    debtRatioA = strategy.calcDebtRatioA()
    debtRatioB = strategy.calcDebtRatioB()

    collatRatio = strategy.calcCollateral()
    print('debtRatioA:   {0}'.format(debtRatioA))
    print('debtRatioB:   {0}'.format(debtRatioB))
    print('collatRatio: {0}'.format(collatRatio))

    assert pytest.approx(strategy.collatTarget(), rel=1e-2) == collatRatio

    withdrawPct = 1
    withdrawAmt = int(amount*withdrawPct)

    # check impact of offseting debt ratios on assets 
    lossAdj = strategy.estimatedTotalAssets() / amount 
    user_balance_before = token.balanceOf(user)
    vault.withdraw(withdrawAmt, user, 500, {'from' : user}) 

    assert (
        pytest.approx(token.balanceOf(user), rel=1e-2) == user_balance_before + withdrawPct*lossAdj*amount
    )
    assert( 
        pytest.approx(strategy.estimatedTotalAssets(), rel = 2e-3) == amount*(1-withdrawPct)*lossAdj
    )


def test_Sandwhich_A(
    chain, gov, accounts, token, vault, strategy, user, strategist, lp_token ,amount, RELATIVE_APPROX, conf, router

):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest

    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    balBefore = token.balanceOf(user)

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # do a big swap to offset debt ratio's massively 
    swapPct = 0.7
    offSetDebtRatioA(strategy, lp_token, token, Contract, swapPct, router)

    offsetEstimatedAssets  = strategy.estimatedTotalAssets()
    strategyLoss = amount - strategy.estimatedTotalAssets()
    lossPercent = strategyLoss / amount

    # check debt ratio
    debtRatioA = strategy.calcDebtRatioA()
    debtRatioB = strategy.calcDebtRatioB()

    collatRatio = strategy.calcCollateral()
    print('debtRatioA:   {0}'.format(debtRatioA))
    print('debtRatioB:   {0}'.format(debtRatioB))
    print('collatRatio: {0}'.format(collatRatio))

    print("Try to rebalance - this should fail due to _testPriceSource()")
    with brownie.reverts():
        strategy.rebalanceDebt()

    assert debtRatioA == strategy.calcDebtRatioA()
    assert debtRatioB == strategy.calcDebtRatioB()

    chain.sleep(1)
    chain.mine(1)
    balBefore = token.balanceOf(user)

    #give RPC a little break to stop it spzzing out 
    time.sleep(5)
    percentWithdrawn = 0.7

    withdrawAmt = int(amount * percentWithdrawn)

    with brownie.reverts():     
        vault.withdraw({'from' : user}) 

def test_Sandwhich_B(
    chain, gov, accounts, token, vault, strategy, user, strategist, lp_token ,amount, RELATIVE_APPROX, conf, router
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    balBefore = token.balanceOf(user)

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # do a big swap to offset debt ratio's massively 
    swapPct = 0.7
    offSetDebtRatioB(strategy, lp_token, token, Contract, swapPct, router)

    print("Try to rebalance - this should fail due to _testPriceSource()")
    # for some reason brownie.reverts doesn't fail.... here although transaction reverts... 
    with brownie.reverts():     
        strategy.rebalanceDebt()

    # check debt ratio
    debtRatioA = strategy.calcDebtRatioA()
    debtRatioB = strategy.calcDebtRatioB()

    collatRatio = strategy.calcCollateral()
    print('debtRatioA:   {0}'.format(debtRatioA))
    print('debtRatioB:   {0}'.format(debtRatioB))
    print('collatRatio: {0}'.format(collatRatio))

    assert debtRatioA == strategy.calcDebtRatioA()
    assert debtRatioB == strategy.calcDebtRatioB()


    offsetEstimatedAssets  = strategy.estimatedTotalAssets()
    strategyLoss = amount - strategy.estimatedTotalAssets()
    lossPercent = strategyLoss / amount

    chain.sleep(1)
    chain.mine(1)
    balBefore = token.balanceOf(user)

    #give RPC a little break to stop it spzzing out 
    time.sleep(5)
    percentWithdrawn = 0.7

    withdrawAmt = int(amount * percentWithdrawn)

    with brownie.reverts():     
        vault.withdraw({'from' : user}) 
