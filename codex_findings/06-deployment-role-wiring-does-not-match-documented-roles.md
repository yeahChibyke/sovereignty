## Title

Deployment role wiring relies on default admin permissions and does not configure vault manager roles

## Severity

Medium

## Likelihood

Medium

## Very detailed description

The README describes a role-based system where privileged operations are controlled through `SovereigntyAccessManager` with granular function-level role bindings.

The deployment script comments state that the deployer must hold `MARKET_MANAGER_ROLE` and `VAULT_MANAGER_ROLE`.

However, `DeployPerpDEX.s.sol` calls restricted functions before configuring their function roles:

```solidity
vault.setPerpDex(address(perp));
perp.addMarket(...);
```

The script configures PerpDEX function roles only after all vaults are deployed, linked, and markets are added.

This works only if the broadcaster has `ADMIN_ROLE`, because OpenZeppelin `AccessManager` defaults unconfigured restricted target functions to `ADMIN_ROLE`.

There is a second issue: the script configures roles for PerpDEX functions, but it does not configure `MarketVault.setPerpDex()` for each deployed vault. That means future calls to `setPerpDex()` on those vaults remain controlled by the default role, which is `ADMIN_ROLE`, not `VAULT_MANAGER_ROLE`.

Relevant code:

- `script/DeployPerpDEX.s.sol:171` - calls `vault.setPerpDex()`
- `script/DeployPerpDEX.s.sol:174` - calls `perp.addMarket()`
- `script/DeployPerpDEX.s.sol:194` - configures PerpDEX market-manager selectors after those calls
- `script/DeployPerpDEX.s.sol:201` - configures PerpDEX operator selectors
- `script/DeployPerpDEX.s.sol:206` - configures PerpDEX pauser selector

## Very detailed and well-explained scenario

1. The protocol deploys `SovereigntyAccessManager`.

2. The deployer is granted `MARKET_MANAGER_ROLE` and `VAULT_MANAGER_ROLE`, as described by the deployment comments.

3. The deployer is not the `ADMIN_ROLE` holder.

4. The deployer runs `DeployPerpDEX.s.sol`.

5. The script deploys PerpDEX and a vault.

6. The script calls:

   ```solidity
   vault.setPerpDex(address(perp));
   ```

7. But `MarketVault.setPerpDex()` has not been assigned to `VAULT_MANAGER_ROLE`.

8. AccessManager therefore treats it as an unconfigured restricted function, which requires `ADMIN_ROLE`.

9. The call reverts.

10. The deployment flow fails even though the deployer has the roles that the script says are required.

A second scenario affects later operations:

1. Deployment is run by the admin, so it succeeds.

2. The script never assigns `MarketVault.setPerpDex()` to `VAULT_MANAGER_ROLE`.

3. Later, the protocol wants to migrate or relink a vault.

4. The `VAULT_MANAGER_ROLE` holder cannot call `setPerpDex()`.

5. Only the admin can call it, because the function remains on the default role.

This breaks the intended operational separation between admin and vault manager.

## Impact

- Deployment can fail if run by an account with only the documented roles.
- The deployed system may not enforce the intended `VAULT_MANAGER_ROLE` permissions.
- Future vault relinking may require admin privileges unexpectedly.
- Operational procedures and emergency response can fail because documented roles do not match actual access control.
- The role model is harder to audit because deployment behavior depends on AccessManager defaults.

## Recommended Mitigation

Configure function roles before calling restricted functions.

A safer deployment order is:

1. Deploy PerpDEX.
2. Deploy each MarketVault.
3. Configure `MarketVault.setPerpDex()` on each vault to `VAULT_MANAGER_ROLE`.
4. Configure `PerpDEX.addMarket()`, `disableMarket()`, and `updateMarketParams()` to `MARKET_MANAGER_ROLE`.
5. Configure operator and pauser functions.
6. Call `vault.setPerpDex()`.
7. Call `perp.addMarket()`.

Also update the deployment script to explicitly configure vault roles:

```solidity
bytes4[] memory vaultMgrSelectors = new bytes4[](1);
vaultMgrSelectors[0] = MarketVault.setPerpDex.selector;
sam.setTargetFunctionRole(address(vault), vaultMgrSelectors, sam.VAULT_MANAGER_ROLE());
```

Add a deployment test that runs the script or equivalent setup using an account that has only `MARKET_MANAGER_ROLE` and `VAULT_MANAGER_ROLE`, not `ADMIN_ROLE`.
