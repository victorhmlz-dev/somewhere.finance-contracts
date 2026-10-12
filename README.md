# somewhere.finance-contracts

Contratos inteligentes de Somewhere Finance para lanzar tokens fungibles en las cadenas EVM: Ethereum, BNB Chain y Robinhood Chain. Stack: Solidity 0.8.28, Hardhat 3, OpenZeppelin 5, tests en TypeScript (viem) y en Solidity (forge-std).

Solana usa otro lenguaje y otro modelo; sus programas irán en un proyecto aparte.

**Estado: en desarrollo y sin auditar.** Solo se ha ejecutado en la red simulada de Hardhat. No debe desplegarse en una red con dinero real hasta pasar una auditoría externa.

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
npm run demo:local    # en otra terminal: despliega el Launchpad y crea tres lanzamientos
```

`demo:local` deja un lanzamiento listado, uno en curso y uno por empezar, e imprime la línea de configuración que hay que pegar en el `.env` del back. Usa el doble del exchange y las cuentas públicas de Hardhat: nada de ahí tiene valor.

## Estructura

```
contracts/Launchpad.sol        Crea los lanzamientos y fija sus límites
contracts/TokenSale.sol        La venta de un token: contribuciones, listado, reembolsos
contracts/CreatorVesting.sol   Lo que se le debe al creador, liberado por tramos mensuales
contracts/LaunchToken.sol      El token que se lanza: un ERC-20 de supply fijo
contracts/interfaces/          Lo que se usa del exchange (Uniswap V2 y compatibles)
contracts/test/                Dobles del exchange, solo para los tests
test/Launchpad.ts              Tests unitarios
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

Los 7 días de gracia existen para que el dinero nunca quede atrapado: si el exchange rechaza el listado, la venta pasa a fallida sola, sin que nadie tenga que intervenir. **Una venta exitosa hay que finalizarla dentro de ese plazo**; conviene que el backend lo haga automáticamente.

### Qué puede hacer la plataforma

La dueña del `Launchpad` solo puede:

- Cambiar la comisión de los lanzamientos futuros, nunca por encima del 1%.
- Cambiar la dirección que cobra las comisiones.

No tiene ningún poder sobre un lanzamiento ya creado ni sobre sus fondos, y no puede pausar ni cancelar ventas. No hay proxies ni actualizaciones: una versión nueva del protocolo es un despliegue nuevo y los lanzamientos anteriores conservan sus reglas.

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

## Lo que estas reglas no garantizan

- Que un token valga algo o conserve su precio.
- Que una persona no use varias wallets para saltarse el máximo por wallet o para comprar en su propia venta.
- Que el creador siga con el proyecto: cobra cada tramo ya vencido pase lo que pase.
- Que los contratos no tengan errores. Por eso no deben usarse con dinero real sin auditoría.

## Despliegue

El `Launchpad` se despliega una vez por cadena, con el exchange y la moneda nativa envuelta de esa cadena:

1. Prepara el archivo de parámetros de la red. El de Sepolia ya existe (`ignition/parameters/sepolia.json`): solo hay que poner en `owner` y `feeRecipient` la dirección pública de la wallet de despliegue. Para otra red, copia `example.json`. `dexFactory` es la fábrica de pares del exchange y `weth` la moneda nativa envuelta; **tómalas de la documentación oficial del exchange**, porque una dirección equivocada dejaría la liquidez de todos los lanzamientos en el contrato equivocado.
2. Guarda cifradas la URL del nodo y las tres claves de testnet, con `npx hardhat keystore set <NOMBRE>`: `SEPOLIA_RPC_URL`, `DEPLOYER_PRIVATE_KEY` (despliega y es la cuenta por defecto), `TEST_WALLET_1_PRIVATE_KEY` y `TEST_WALLET_2_PRIVATE_KEY` (hacen de usuarios en las pruebas manuales).
3. Despliega: `npx hardhat ignition deploy ignition/modules/Launchpad.ts --network sepolia --parameters ignition/parameters/sepolia.json`.

Las redes configuradas están en `hardhat.config.ts`: `sepolia`, `bscTestnet` y `robinhoodTestnet`.

### Direcciones de Uniswap V2

Tomadas de la [página oficial de despliegues](https://developers.uniswap.org/docs/protocols/v2/deployments) el 2026-10-12. Compruébalas allí de nuevo antes de desplegar.

| Red | Fábrica de pares | Estado |
|---|---|---|
| Ethereum Sepolia | `0xF62c03E08ada871A0bEb309762E260a7a6a880E6` | Probada con `npm run test:fork` |
| Ethereum | `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f` | Sin probar |
| BNB Chain | `0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6` | Sin probar |
| Robinhood Chain | `0x8bceaa40b9acdfaedf85adf4ff01f5ad6517937f` | Sin probar |

La moneda nativa envuelta de Sepolia es `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`, leída del propio router de Uniswap. La de las otras redes está por confirmar, igual que las fábricas de sus testnets.

## Pendiente antes de una red real

- Desplegar y probar a mano en Sepolia.
- Repetir la prueba contra el exchange real en BNB Chain y Robinhood Chain.
- Análisis estático con Slither.
- Auditoría externa.
