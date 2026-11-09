# TokenLocker

Contrat de **lock simple** de tokens ERC-20 sur **Elysium** (chain ID 99901) : les tokens sont bloqués jusqu'à une date, puis le propriétaire du lock retire tout d'un coup.

> ⚠️ Ce code n'a pas encore été audité. Teste-le sur de petits montants avant d'y mettre des fonds importants.

## Garanties

- **Personne d'autre que le propriétaire du lock ne peut retirer les tokens**, même pas l'admin du contrat. L'admin n'a aucune fonction qui touche aux tokens bloqués.
- **Pas de pause.** Rien ne peut empêcher un retrait une fois la date passée.
- **Un lock ne peut jamais être raccourci ni annulé**, seulement prolongé par son propriétaire.
- **Frais plafonnés dans le code** : `MAX_FEE = 1 HYPE`, valeur non modifiable. L'admin ne peut changer que le montant des frais (sous ce plafond) et l'adresse qui les reçoit.
- **Admin en deux étapes** (`Ownable2Step`) : un transfert de propriété doit être accepté par la nouvelle adresse, ce qui évite les erreurs de saisie.
- **Tokens à taxe de transfert refusés** à la création : le contrat vérifie que la quantité reçue correspond exactement au montant indiqué.
- Protection contre la réentrance sur `lock`, `withdraw` et `withdrawFees`.

## Fonctions

| Fonction | Qui | Effet |
|---|---|---|
| `lock(token, amount, unlockTime, owner)` | tout le monde, en payant `fee` en HYPE | Bloque `amount` jusqu'à `unlockTime`. Il faut d'abord `approve` le contrat. |
| `withdraw(id)` | propriétaire du lock, après `unlockTime` | Envoie tous les tokens au propriétaire. |
| `extendLock(id, newUnlockTime)` | propriétaire du lock | Repousse la date de déblocage (jamais plus tôt). |
| `transferLock(id, to)` | propriétaire du lock | Donne le lock à une autre adresse. |
| `withdrawFees()` | tout le monde | Envoie les frais collectés à `feeRecipient`. |
| `setFee(fee)` / `setFeeRecipient(addr)` | admin | Règle les frais (≤ 1 HYPE). |
| `getLock(id)`, `lockCount()` | lecture | Détails d'un lock, nombre total de locks. |
| `userLockIds(user, offset, limit)` | lecture | Locks d'une adresse. La liste garde aussi les locks transférés depuis : vérifie `getLock(id).owner`. |
| `tokenLockIds(token, offset, limit)` | lecture | Tous les locks d'un token, par exemple pour prouver qu'une liquidité est bloquée. |

Les limites : `unlockTime` doit être dans le futur et au plus à 100 ans (`MAX_LOCK_DURATION`), ce qui permet d'attraper une date saisie en millisecondes. Les tokens « rebasing », dont le solde change tout seul, ne sont pas supportés.

## Développement

```bash
npm install
```

```bash
npm test
```

La suite comprend 34 tests :
- des tests unitaires ;
- des tests sur valeurs aléatoires (1000 exécutions chacun) ;
- 2 invariants vérifiés sur des séquences aléatoires de création, retrait, prolongation, transfert et avance dans le temps : le contrat détient toujours exactement la somme des locks non retirés, et son solde en HYPE correspond exactement aux frais collectés.

Compilation : Solidity 0.8.28, version EVM `shanghai`, optimiseur à 200 exécutions. Le déploiement a été simulé sur le RPC d'Elysium : environ 1,34 M de gas.

## Déployer sur Elysium

1. Enregistre ta clé privée de déploiement, chiffrée en local (elle ne quitte jamais ta machine) :
   ```bash
   npx hardhat keystore set ELYSIUM_PRIVATE_KEY
   ```
2. Optionnel : crée `ignition/parameters.json` pour choisir l'admin, le destinataire des frais et le montant (par défaut : l'adresse qui déploie, et 0,05 HYPE) :
   ```json
   { "TokenLockerModule": { "owner": "0x…", "feeRecipient": "0x…", "fee": "50000000000000000" } }
   ```
3. Déploie :
   ```bash
   npm run deploy -- --parameters ignition/parameters.json
   ```

Conseil : utilise un multisig comme `owner`. Le pire qu'un admin compromis puisse faire est de monter les frais à 1 HYPE, mais autant l'éviter.

## Vérifier le contrat déployé

Elyscan ne propose pas encore la vérification du code source (« coming soon »). À la place, n'importe qui peut recompiler ce repo et comparer avec le contrat sur la blockchain :

```bash
npx hardhat compile && npm run check-bytecode -- <adresse_du_contrat>
```

`MATCH` signifie que le contrat déployé est exactement ce code.
