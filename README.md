# Elysian Pyre 🔥

Dans la Grèce antique, le bûcher funéraire (*pyre*) envoyait les âmes vers l'Élysée. **Elysian Pyre** fait la même chose avec tes tokens sur **Elysium** (chain ID 99901) :

- **Lock** : les tokens attendent sur le bûcher jusqu'à une date, puis leur propriétaire les récupère.
- **Lock permanent** : les tokens restent bloqués pour toujours, par exemple pour sceller une liquidité.
- **Burn** : les tokens sont détruits pour de bon et le total brûlé est enregistré pour chaque token.

> ⚠️ Ce code n'a pas encore été audité. Teste-le sur de petits montants avant d'y mettre des fonds importants.

## Garanties

- **Personne d'autre que le propriétaire du lock ne peut retirer les tokens**, même pas l'admin du contrat. L'admin n'a aucune fonction qui touche aux tokens.
- **Pas de pause.** Rien ne peut empêcher un retrait une fois la date passée.
- **Un lock ne peut jamais être raccourci ni annulé.** Son propriétaire peut seulement le prolonger, y compris en lock permanent. Un lock permanent ne peut plus jamais être retiré.
- **Le contrat ne garde jamais les tokens brûlés.** Il appelle d'abord la fonction `burn()` du token, ce qui réduit vraiment sa `totalSupply`. Si le token n'a pas de `burn()` fonctionnel, les tokens partent à l'adresse morte `0x000000000000000000000000000000000000dEaD`. Si le `burn()` du token détruit un autre montant que prévu, l'opération est annulée.
- **Frais plafonnés dans le code** : `MAX_FEE = 1 HYPE`, valeur non modifiable. L'admin ne peut changer que le montant des frais (sous ce plafond) et l'adresse qui les reçoit.
- **Admin en deux étapes** (`Ownable2Step`) : un transfert de propriété doit être accepté par la nouvelle adresse.
- **Tokens à taxe de transfert refusés pour les locks.** Pour un burn, c'est la quantité réellement reçue qui est brûlée et enregistrée.
- Protection contre la réentrance sur toutes les fonctions qui déplacent des fonds.

## Fonctions

| Fonction | Qui | Effet |
|---|---|---|
| `lock(token, amount, unlockTime, owner)` | tout le monde, en payant `fee` | Bloque `amount` jusqu'à `unlockTime`. Avec `PERMANENT` comme date, le lock est éternel. |
| `lockPermanent(token, amount, owner)` | tout le monde, en payant `fee` | Bloque `amount` pour toujours. |
| `burn(token, amount)` | tout le monde, en payant `fee` | Détruit `amount`. Renvoie la quantité brûlée et indique si la supply a baissé. |
| `withdraw(id)` | propriétaire du lock, après `unlockTime` | Envoie tous les tokens au propriétaire. Impossible pour un lock permanent. |
| `extendLock(id, newUnlockTime)` | propriétaire du lock | Repousse la date (jamais plus tôt), éventuellement à `PERMANENT`. |
| `transferLock(id, to)` | propriétaire du lock | Donne le lock à une autre adresse. |
| `withdrawFees()` | tout le monde | Envoie les frais collectés à `feeRecipient`. |
| `setFee(fee)` / `setFeeRecipient(addr)` | admin | Règle les frais (≤ 1 HYPE). |
| `getLock(id)`, `lockCount()`, `isPermanent(id)` | lecture | Détails d'un lock. |
| `totalBurned(token)` | lecture | Total brûlé pour un token via Elysian Pyre. |
| `userLockIds(user, offset, limit)` | lecture | Locks d'une adresse. La liste garde aussi les locks transférés depuis : vérifie `getLock(id).owner`. |
| `tokenLockIds(token, offset, limit)` | lecture | Tous les locks d'un token, par exemple pour prouver qu'une liquidité est bloquée. |

Pour `lock`, `lockPermanent` et `burn`, il faut d'abord `approve` le contrat pour le montant, et envoyer exactement `fee` en HYPE (0,1 HYPE par défaut).

Les limites : un lock à durée fixe doit se terminer dans le futur et au plus dans 100 ans (`MAX_LOCK_DURATION`). Les tokens « rebasing », dont le solde change tout seul, ne sont pas supportés.

## Développement

```bash
npm install
```

```bash
npm test
```

La suite comprend 49 tests :
- des tests unitaires ;
- des tests sur valeurs aléatoires (1000 exécutions chacun) ;
- 3 invariants vérifiés sur des séquences aléatoires de lock, lock permanent, burn, retrait, prolongation, transfert et avance dans le temps :
  - le contrat détient toujours exactement les tokens des locks non retirés ;
  - son solde en HYPE correspond exactement aux frais collectés ;
  - chaque token brûlé est comptabilisé, et aucun ne reste dans le contrat.

Compilation : Solidity 0.8.28, version EVM `shanghai`, optimiseur à 200 exécutions. Le déploiement a été simulé sur le RPC d'Elysium : environ 1,69 M de gas, soit moins de 0,0002 HYPE.

## Déployer sur Elysium

1. Enregistre ta clé privée de déploiement, chiffrée en local (elle ne quitte jamais ta machine) :
   ```bash
   npx hardhat keystore set ELYSIUM_PRIVATE_KEY
   ```
2. Optionnel : crée `ignition/parameters.json` pour choisir l'admin, le destinataire des frais et le montant (par défaut : l'adresse qui déploie, et 0,1 HYPE) :
   ```json
   { "ElysianPyreModule": { "owner": "0x…", "feeRecipient": "0x…", "fee": "100000000000000000" } }
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
