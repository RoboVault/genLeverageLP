import pytest
from brownie import config
from brownie import Contract
from brownie import interface, project

 # TODO - Pull from coingecko
LQDR_PRICE = 15
SPOOKY_PRICE = 11.78
SPIRIT_PRICE = 5.78

WETH_PRICE = 3400


SPOOKY_MASTERCHEF = '0x2b2929E785374c651a81A63878Ab22742656DcDd'
BOO = '0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE'

lqdrMasterChef = '0x6e2ad6527901c9664f016466b8DA1357a004db0f'
lqdr = '0x10b620b2dbAC4Faa7D7FFD71Da486f5D44cd86f9'

SPIRIT_ROUTER = '0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52'
SPOOKY_ROUTER = '0xF491e7B69E4244ad4002BC14e878a34207E38c29'

CONFIG = {
    'USDCWFTMCRVScreamSpooky': {
        'token': '0x04068DA6C83AFCFA0e13ba15A6696662335D5B75',
        'whale': '0xe578C856933D8e1082740bf7661e379Aa2A30b26',
        'deposit': 1e6,
        'harvest_token': '0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE',
        'harvest_token_price': SPOOKY_PRICE * 1e-12,
        'harvest_token_whale': '0xa48d959AE2E88f1dAA7D5F611E01908106dE7598',
        'lp_token': '0xB471Ac6eF617e952b84C6a9fF5de65A9da96C93B',
        'lp_whale': '0x2b2929E785374c651a81A63878Ab22742656DcDd',
        'lp_farm': '0x2b2929E785374c651a81A63878Ab22742656DcDd',
        'pid': 14,
        'router': SPOOKY_ROUTER,

    },
    'USDCWFTMLINKScreamSpooky': {
        'token': '0x04068DA6C83AFCFA0e13ba15A6696662335D5B75',
        'whale': '0xe578C856933D8e1082740bf7661e379Aa2A30b26',
        'deposit': 1e6,
        'harvest_token': '0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE',
        'harvest_token_price': SPOOKY_PRICE * 1e-12,
        'harvest_token_whale': '0xa48d959AE2E88f1dAA7D5F611E01908106dE7598',
        'lp_token': '0x89d9bC2F2d091CfBFc31e333D6Dc555dDBc2fd29',
        'lp_whale': '0x7F41312B5D2D31D49482F31C9a53e6485Df37E1D',
        'lp_farm': '0x2b2929E785374c651a81A63878Ab22742656DcDd',
        'pid': 6,
        'router': SPOOKY_ROUTER,

    },
    'WETHWFTMLINKScreamSpooky': {
        'token': '0x74b23882a30290451A17c44f4F05243b6b58C76d',
        'whale': '0x613BF4E46b4817015c01c6Bb31C7ae9edAadc26e',
        'deposit': 1e6,
        'harvest_token': '0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE',
        'harvest_token_price': SPOOKY_PRICE / WETH_PRICE,
        'harvest_token_whale': '0xa48d959AE2E88f1dAA7D5F611E01908106dE7598',
        'lp_token': '0x89d9bC2F2d091CfBFc31e333D6Dc555dDBc2fd29',
        'lp_whale': '0x7F41312B5D2D31D49482F31C9a53e6485Df37E1D',
        'lp_farm': '0x2b2929E785374c651a81A63878Ab22742656DcDd',
        'pid': 6,
        'router': SPOOKY_ROUTER,

    },

    'WETHWFTMLINKScreamLqdrSpooky': {
        'token': '0x74b23882a30290451A17c44f4F05243b6b58C76d',
        'whale': '0x613BF4E46b4817015c01c6Bb31C7ae9edAadc26e',
        'deposit': 1e6,
        'harvest_token': lqdr,
        'harvest_token_price': LQDR_PRICE / WETH_PRICE,
        'harvest_token_whale': lqdrMasterChef,
        'lp_token': '0x89d9bC2F2d091CfBFc31e333D6Dc555dDBc2fd29',
        'lp_whale': '0x7F41312B5D2D31D49482F31C9a53e6485Df37E1D',
        'lp_farm': lqdrMasterChef,
        'pid': 14,
        'router': SPOOKY_ROUTER,

    }

}


@pytest.fixture
def strategy_contract():
    yield  project.GenleveragelpProject.WETHWFTMLINKScreamLqdrSpooky


@pytest.fixture
def conf(strategy_contract):
    yield CONFIG[strategy_contract._name]

@pytest.fixture
def gov(accounts):
    yield accounts.at("0x7601630eC802952ba1ED2B6e4db16F699A0a5A87", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token(conf):
    # token_address = "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75"  # USDC
    # token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield interface.IERC20Extended(conf['token'])


@pytest.fixture
def amount(accounts, token, user, conf):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    # reserve = accounts.at("0x39B3bd37208CBaDE74D0fcBDBb12D606295b430a", force=True) # WFTM
    # reserve = accounts.at("0x2dd7C9371965472E5A5fD28fbE165007c61439E1", force=True) # USDC
    reserve = accounts.at(conf['whale'], force=True)
    
    whaleBalance = token.balanceOf(reserve)
    amount = min(amount, int(0.02*whaleBalance))
    
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"
    yield interface.IERC20Extended(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout

@pytest.fixture
def router(conf):
    yield Contract(conf['router'])



@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    assert vault.token() == token.address
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, strategy_contract, gov):
    strategy = strategist.deploy(strategy_contract, vault)
    #insurance = strategist.deploy(StrategyInsurance, strategy)
    strategy.setKeeper(keeper)
    #strategy.setInsurance(insurance, {'from': gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5

@pytest.fixture
def lp_token(conf):
    yield interface.ERC20(conf['lp_token'])

@pytest.fixture
def lp_whale(accounts, conf):
    yield accounts.at(conf['lp_whale'], True)

@pytest.fixture
def harvest_token(conf):
    yield Contract(conf['harvest_token'])

@pytest.fixture
def harvest_token_whale(conf, accounts):
    yield accounts.at(conf['harvest_token_whale'], True)

@pytest.fixture
def whale(conf, accounts):
    yield accounts.at(conf['whale'], True)

@pytest.fixture
def pid(conf):
    yield conf['pid']

@pytest.fixture
def lp_farm(conf):
    if (conf['harvest_token'] == '0x10b620b2dbAC4Faa7D7FFD71Da486f5D44cd86f9'): # LQDR
        yield interface.LqdrFarm(conf['lp_farm'])
    else:
        yield interface.IFarmMasterChef(conf['lp_farm'])

@pytest.fixture
def lp_price(token, lp_token):
    yield (token.balanceOf(lp_token) * 2) / lp_token.totalSupply()  

@pytest.fixture
def deployed_vault(chain, accounts, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    
    # harvest
    chain.sleep(1)
    ##strategy.approveContracts({'from':gov})
    strategy.harvest()
    strat = strategy
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    yield vault  



def steal(stealPercent, strategy, token, chain, gov, user):
    steal = round(strategy.estimatedTotalAssets() * stealPercent)
    strategy.liquidatePositionAuth(steal, {'from': gov})
    token.transfer(user, strategy.balanceOfWant(), {"from": accounts.at(strategy, True)})
    chain.sleep(1)
    chain.mine(1)


# Function scoped isolation fixture to enable xdist.
# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass

