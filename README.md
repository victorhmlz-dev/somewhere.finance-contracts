# somewhere.finance-contracts

Contratos inteligentes de Somewhere Finance para lanzar tokens fungibles en las cadenas EVM: Ethereum, BNB Chain y Robinhood Chain. Stack: Solidity 0.8.28, Hardhat 3, OpenZeppelin 5, tests en TypeScript (viem) y en Solidity (forge-std).

Solana usa otro lenguaje y otro modelo; sus programas irán en un proyecto aparte.

**Estado: en desarrollo y sin auditar.** Desplegado solo en Sepolia, una red de pruebas. No debe desplegarse en una red con dinero real hasta pasar una auditoría externa.

El diseño, el modelo de amenazas, las invariantes y las decisiones pendientes están en [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Puesta en marcha

Requiere Node.js 22.12 o superior.

```bash
npm install
npm test                      # compila y ejecuta todos los tests
npx hardhat test nodejs       # solo los unitarios (TypeScript)
npx hardhat test solidity     # solo fuzzing e invariantes (Solidity)
npm run build                 # solo compila
```

Hay además una prueba contra el Uniswap V2 real de Sepolia. Trabaja sobre una copia local de esa cadena, no envía nada a la red, y sin la URL de un nodo se salta sola:

```bash
SEPOLIA_FORK_URL=https://ethereum-sepolia-rpc.publicnode.com npm run test:fork
```

### Cadena local para desarrollar el back y el front

```bash
npm run node          # arranca una cadena local en http://127.0.0.1:8545; déjala abierta
npm run demo:local    # en otra terminal: despliega el Launchpad y crea cuatro lanzamientos
```

`demo:local` despliega un Launchpad v2 y uno v3 y una stablecoin de prueba (MUSD, 6 decimales, repartida a todas las cuentas). Deja en la v2 un lanzamiento listado, uno en curso, uno por empezar y uno cancelado, y en la v3 uno en MUSD en curso y uno en ETH por empezar. Imprime la línea `CHAINS=…` que hay que pegar en el `.env` del back. Usa el doble del exchange y las cuentas públicas de Hardhat: nada de ahí tiene valor.

## Estructura

```
contracts/Launchpad.sol        Crea los lanzamientos y fija sus límites (v2, desplegada)
contracts/TokenSale.sol        La venta de un token: contribuciones, listado, reembolsos (v2)
contracts/CreatorVesting.sol   Lo que se le debe al creador, liberado por tramos mensuales (v2)
contracts/LaunchpadV3.sol      v3: pares con cualquier activo permitido, tickers, tokens oficiales
contracts/TokenSaleV3.sol      v3: la venta, clonada para cada lanzamiento
contracts/CreatorVestingV3.sol v3: el vesting, clonado para cada lanzamiento
contracts/LaunchToken.sol      El token que se lanza: un ERC-20 de supply fijo
contracts/interfaces/          Lo que se usa del exchange (Uniswap V2 y compatibles)
contracts/test/                Dobles del exchange y de activos con emisor, solo para los tests
test/Launchpad.ts              Tests unitarios
test/LaunchpadV3.ts            Tests unitarios de la v3
test/LaunchpadV3Invariant.t.sol Propiedades de la v3, también ante pausas y quemas del emisor
test/LaunchpadFuzz.t.sol       Tests con entradas aleatorias
test/LaunchpadInvariant.t.sol  Propiedades que se cumplen tras cualquier secuencia de acciones
test/LaunchpadFork.t.sol       Un lanzamiento completo contra el Uniswap V2 real de Sepolia
ignition/                      Despliegue
scripts/local-demo.ts          Lanzamientos de ejemplo en la cadena local
docs/                          Arquitectura y decisiones
```

## Somewhere Launchpad: ventas a precio fijo

Cualquiera puede crear un lanzamiento llamando a `Launchpad.createLaunch`. Cada lanzamiento despliega un token nuevo, un contrato de venta que recibe todo el supply y un contrato de vesting para el creador. Nada de un lanzamiento se puede cambiar una vez creado.

### Lo que el contrato hace cumplir

| Regla | Valor |
|---|---|
| Parte de lo recaudado que va a liquidez | Al menos el 70% |
| Bloqueo de la liquidez | Para siempre: los tokens del pool van a `0x…dEaD` |
| Tokens para el creador | Como máximo el 1% del supply |
| Cobro del creador (dinero y tokens) | Por tramos mensuales iguales, mínimo 3 y máximo 48; el primero a los 30 días del listado |
| Comisión de la plataforma | 0,5% de lo recaudado hoy; nunca más del 1% |
| Venta fallida | Reembolso íntegro, sin comisión |
| Cancelación | Solo el creador y solo antes de que empiece la venta; se quema todo el supply |
| Supply | Fijo; nadie puede acuñar más |

### Reparto de lo recaudado

En una venta exitosa, el propio contrato reparte lo recaudado al listar:

1. **Liquidez** (el porcentaje que eligió el creador, del 70% en adelante): va al exchange emparejada con tokens al precio de la venta.
2. **Comisión**: queda apartada en la venta hasta que la plataforma la retira.
3. **El resto**: va al contrato de vesting del creador, junto con sus tokens.

### Reparto del supply

Para que el token salga a negociarse al mismo precio de la venta, los tokens reservados para liquidez guardan la misma proporción que el dinero. Con el 70% a liquidez y el 1% al creador: 58,2% a la venta y 40,8% a la reserva de liquidez. Lo que no se vende se quema, junto con su parte de la reserva.

### Ciclo de una venta

El precio sale de dividir el máximo a recaudar (`hardCap`) entre los tokens en venta.

| Estado | Qué pasa |
|---|---|
| `Upcoming` | Aún no ha llegado `startTime` |
| `Live` | Se aceptan contribuciones (`contribute`, o enviando moneda nativa al contrato). Lo que no cabe, bajo el `hardCap` o bajo el máximo por wallet, se devuelve en la misma transacción |
| `Succeeded` | Se alcanzó el `hardCap`, o llegó `endTime` con al menos el `softCap`. Cualquiera puede llamar a `finalize` durante 7 días |
| `Finalized` | El token está listado. Cada contribuyente retira sus tokens con `claim` y empieza el vesting del creador |
| `Failed` | Llegó `endTime` sin alcanzar el `softCap`, o pasaron los 7 días sin que la venta se pudiera listar. Cada contribuyente recupera todo con `refund` |
| `Cancelled` | El creador llamó a `cancel` antes de `startTime`. Nadie pudo aportar todavía, así que no hay nada que devolver; todo el supply va a `0x…dEaD` y el token nunca cotiza. Es definitivo |

Los 7 días de gracia existen para que el dinero nunca quede atrapado: si el exchange rechaza el listado, la venta pasa a fallida sola, sin que nadie tenga que intervenir. **Una venta exitosa hay que finalizarla dentro de ese plazo**; conviene que el backend lo haga automáticamente.

### Qué puede hacer la plataforma

La dueña del `Launchpad` solo puede:

- Cambiar la comisión de los lanzamientos futuros, nunca por encima del 1%.
- Cambiar la dirección que cobra las comisiones.

No tiene ningún poder sobre un lanzamiento ya creado ni sobre sus fondos, y no puede pausar ni cancelar ventas. Cancelar solo lo puede el creador de cada lanzamiento, y solo antes de que empiece. No hay proxies ni actualizaciones: una versión nueva del protocolo es un despliegue nuevo y los lanzamientos anteriores conservan sus reglas.

### Límites de un lanzamiento

| Parámetro | Límite |
|---|---|
| Supply | De 1.000 a 10^15 tokens, con 18 decimales |
| `softCap` | Al menos 0,01 de moneda nativa y no mayor que `hardCap` |
| Inicio | Como mucho 90 días después de crearse |
| Duración | Como mucho 30 días |
| Liquidez | Del 70% al 100% menos la comisión |
| Tramos de vesting | De 3 a 48 |
| Mínimo y máximo por wallet | Opcionales. El mínimo se mide sobre el total aportado por la wallet |

## Somewhere Launchpad v3: pares con cualquier activo

La v3 mantiene las reglas de la v2 (liquidez bloqueada, 1% como máximo para el creador, vesting, comisión de hasta el 1%, reembolsos, cancelación antes del inicio) y añade:

- **Par con cualquier activo permitido.** El creador elige con qué se compra y se empareja su token: una stablecoin (USDC, o USDG en Robinhood Chain), una acción tokenizada, otra cripto o la moneda nativa a través de su versión envuelta. La dueña permite cada activo con `setQuoteAsset`, con su propio mínimo de `softCap`; quitar un activo solo afecta a lanzamientos nuevos.
- **Tres formas de aportar.** `contribute(amount, proof)` tras aprobar el gasto; `contributeWithPermit` con una firma EIP-2612 (USDC, USDG y las acciones de Robinhood la admiten); `contributeNative(proof)` cuando el par es la moneda nativa, que la venta envuelve. Solo se cobra lo que cabe. Los tokens que entregan menos de lo enviado (con comisión por transferencia) se rechazan.
- **Pagos en moneda nativa con respaldo.** Si el par es la moneda nativa, reembolsos, comisión y vesting se pagan en ella; a una dirección que no puede recibirla se le paga la versión envuelta, para que nada quede atascado.
- **Activos con emisor.** Una pausa solo retrasa: si dura más que el plazo de gracia, la venta pasa a reembolsos, que funcionan en cuanto el emisor la levanta. Una dirección bloqueada solo afecta a esa persona. Si el emisor quema fondos de la venta (`adminBurn` en las acciones de Robinhood), no se lista y los reembolsos reparten la pérdida a prorrata en lugar de dejar sin nada a los últimos (`Refunded(contributor, contribution, amount)`).
- **Tickers.** De 1 a 10 caracteres A–Z y 0–9. Un ticker solo puede tenerlo un lanzamiento a la vez en cada Launchpad; se libera con `releaseTicker(launchId)` cuando ese lanzamiento se cancela o falla. `isTickerAvailable(symbol)` lo consulta.
- **Tokens oficiales.** `isOfficial(token)` y `saleOf(token)` dicen si un token salió de este Launchpad.
- **Niveles de verificación.** Un lanzamiento puede exigir un nivel (`requiredTier`). Quien compra presenta una declaración firmada por el `attestor` que nombra la plataforma (EIP-712: cuenta, nivel y caducidad). La verificación la hace un tercero; a la cadena solo llega el nivel. Con nivel 0, como en la v2, compra cualquiera.
- **Clones.** Cada venta y cada vesting es un clon mínimo (EIP-1167) de una implementación desplegada aparte; las implementaciones no se pueden inicializar. `LaunchpadV3` ocupa 12.975 bytes, `TokenSaleV3` 9.113 y `CreatorVestingV3` 3.271.

En la v3, la dueña puede además permitir o retirar activos para lanzamientos futuros y nombrar o retirar el `attestor`. Retirarlo detiene las compras de los lanzamientos que exigen nivel; si no se nombra otro a tiempo, esas ventas fallan y todos recuperan su aportación.

Despliegue de la v3: `npx hardhat ignition deploy ignition/modules/LaunchpadV3.ts --network <red> --parameters <archivo> --deployment-id <red>-v3`, con un archivo como `ignition/parameters/example-v3.json`. Después, la dueña permite cada activo con `npx hardhat run scripts/allow-quote-assets.ts --network <red>`, que lee la lista de `ignition/parameters/<red>-v3-quote-assets.json` (en Sepolia: ETH y el USDC de Circle, `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`).

## Lo que estas reglas no garantizan

- Que un token valga algo o conserve su precio.
- Que una persona no use varias wallets para saltarse el máximo por wallet o para comprar en su propia venta.
- Que el creador siga con el proyecto: cobra cada tramo ya vencido pase lo que pase.
- Que los contratos no tengan errores. Por eso no deben usarse con dinero real sin auditoría.

## Despliegue

El `Launchpad` se despliega una vez por cadena, con el exchange y la moneda nativa envuelta de esa cadena:

1. Prepara el archivo de parámetros de la red. El de Sepolia ya existe (`ignition/parameters/sepolia.json`): solo hay que poner en `owner` y `feeRecipient` la dirección pública de la wallet de despliegue. Para otra red, copia `example.json`. `dexFactory` es la fábrica de pares del exchange y `weth` la moneda nativa envuelta; **tómalas de la documentación oficial del exchange**, porque una dirección equivocada dejaría la liquidez de todos los lanzamientos en el contrato equivocado.
2. Guarda cifradas la URL del nodo y las tres claves de testnet, con `npx hardhat keystore set <NOMBRE>`: `SEPOLIA_RPC_URL`, `DEPLOYER_PRIVATE_KEY` (despliega y es la cuenta por defecto), `TEST_WALLET_1_PRIVATE_KEY` y `TEST_WALLET_2_PRIVATE_KEY` (hacen de usuarios en las pruebas manuales).
3. Despliega: `npx hardhat ignition deploy ignition/modules/Launchpad.ts --network sepolia --parameters ignition/parameters/sepolia.json --deployment-id sepolia-v2`.

`--deployment-id` da a cada versión su propio registro en `ignition/deployments/`. Para desplegar una versión nueva de los contratos se usa un id nuevo (`sepolia-v3`…), y el registro de las anteriores se conserva. El primer despliegue de Sepolia, sin id, está en `chain-11155111/`.

Las redes configuradas están en `hardhat.config.ts`: `sepolia`, `bscTestnet` y `robinhoodTestnet`.

### Direcciones de Uniswap V2

Tomadas de la [página oficial de despliegues](https://developers.uniswap.org/docs/protocols/v2/deployments) el 2026-10-12. Compruébalas allí de nuevo antes de desplegar.

| Red | Fábrica de pares | Estado |
|---|---|---|
| Ethereum Sepolia | `0xF62c03E08ada871A0bEb309762E260a7a6a880E6` | Probada con `npm run test:fork` |
| Ethereum | `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f` | Sin probar |
| BNB Chain | `0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6` | Sin probar |
| Robinhood Chain | `0x8bceaa40b9acdfaedf85adf4ff01f5ad6517937f` | Leída en la red el 2026-10-16: su router (`0x89e5db8b5aa49aa85ac63f691524311aeb649eba`) apunta a ella y tiene más de 115.000 pares. Sin prueba de lanzamiento completo |

La moneda nativa envuelta de Sepolia es `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` y la de Robinhood Chain `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, leídas de los routers de Uniswap. La de las otras redes está por confirmar, igual que las fábricas de sus testnets. La stablecoin nativa de Robinhood Chain es USDG (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimales), no USDC.

## Despliegues

| Red | Versión | Launchpad | Bloque | Fecha |
|---|---|---|---|---|
| Ethereum Sepolia | v3, pares con ETH y USDC | `0x0EB8Cd03C0544943C1256bbFfF61A44155C32B97` | 11923771 | 2026-10-16 |
| Ethereum Sepolia | v2, con cancelación antes del inicio | `0xB393ef85b97f9A0391cC612Eb97707E7078E0261` | 11916640 | 2026-10-15 |
| Ethereum Sepolia | v1, sustituida | `0x83c968b3E5EeBaaBe78a6f5f9235207d942804e1` | 11915040 | 2026-10-14 |

Dueña y receptora de comisiones en Sepolia: la wallet de despliegue de pruebas, `0xe7002ce14a6f77d2c1db1333DD565e27D773925D`. La v3 usa las implementaciones `TokenSaleV3` `0x729b5e36C684160E2e6C8289267DD6cce6F72a1F` y `CreatorVestingV3` `0xc50171D8561d5a2ebfa70dC05817f8502715d714`, y permite ETH (mínimo 0,01) y el USDC de Circle (mínimo 10); su registro está en `ignition/deployments/sepolia-v3/`. Un primer intento dejó una implementación de vesting sin usar en `0x940eff5e9ac7e6425291bfd9d5aead125d9789cd`, que no está conectada a nada. El registro de la v2 está en `ignition/deployments/sepolia-v2/` y el de la v1 en `ignition/deployments/chain-11155111/`. Sus lanzamientos siguen funcionando con sus reglas, pero la web solo muestra los del Launchpad configurado en el back.

## Pendiente antes de una red real

- Desplegar y probar a mano en Sepolia.
- Repetir la prueba contra el exchange real en BNB Chain y Robinhood Chain, y hacerla para la v3 con USDC/USDG y una acción tokenizada.
- Probar a mano la v3 en Sepolia con USDC y ETH.
- Análisis estático con Slither.
- Auditoría externa.
