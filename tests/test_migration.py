# TODO: Add tests that show proper migration of the strategy to a newer one
#       Use another copy of the strategy to simulate the migration
#       Show that nothing is lost!

import pytest



def test_migration(
    chain,
    token,
    vault,
    strategy,
    amount,
    strategy_contract,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    #strategy.approveContracts({'from':gov})
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # migrate to a new strategy
    new_strategy = strategist.deploy(strategy_contract, vault)
    chain.mine(1)
    chain.sleep(1)
    #new_strategy.approveContracts({'from':gov})
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert (
        pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
        == amount
    )

"""
def test_migration_with_low_calcdebtratio(
    chain,
    token,
    vault,
    strategy,
    amount,
    strategy_contract,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
):
    assert False
    # # Deposit to the vault and harvest
    # token.approve(vault.address, amount, {"from": user})
    # vault.deposit(amount, {"from": user})
    # chain.sleep(1)
    # strategy.approveContracts({'from':gov})
    # strategy.harvest()
    # assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # # migrate to a new strategy
    # new_strategy = strategist.deploy(strategy_contract, vault)
    # new_strategy.approveContracts({'from':gov})
    # vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    # assert (
    #     pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
    #     == amount
    # )

def test_migration_with_high_calcdebtratio(
    chain,
    token,
    vault,
    strategy,
    amount,
    strategy_contract,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
):
    assert False
    # # Deposit to the vault and harvest
    # token.approve(vault.address, amount, {"from": user})
    # vault.deposit(amount, {"from": user})
    # chain.sleep(1)
    # strategy.approveContracts({'from':gov})
    # strategy.harvest()
    # assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # # migrate to a new strategy
    # new_strategy = strategist.deploy(strategy_contract, vault)
    # new_strategy.approveContracts({'from':gov})
    # vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    # assert (
    #     pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
    #     == amount
    # )
"""