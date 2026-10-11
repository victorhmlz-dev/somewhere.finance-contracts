# somewhere.finance-contracts

Contratos inteligentes de Somewhere Finance para las cadenas EVM: Ethereum, BNB Chain y Robinhood Chain. Stack: Solidity 0.8.28, Hardhat 3, OpenZeppelin 5, tests en TypeScript con viem.

Solana usa otro lenguaje y otro modelo; sus programas irán en un proyecto aparte.

**Estado: en desarrollo y sin auditar.** Solo se ha ejecutado en la red simulada de Hardhat. No debe desplegarse en una red con dinero real hasta pasar una auditoría externa.

## Puesta en marcha

Requiere Node.js 22.12 o superior.

```bash
npm install
npm test          # compila y ejecuta los tests
npm run build     # solo compila
```

## Estructura

```
contracts/Launchpad.sol       Crea los lanzamientos y fija sus reglas
contracts/TokenSale.sol       La venta de un token: contribuciones, listado, reembolsos
contracts/LaunchToken.sol     El token que se lanza: un ERC-20 de supply fijo
contracts/interfaces/         Lo que se usa del exchange (Uniswap V2 y compatibles)
contracts/test/               Dobles del exchange, solo para los tests
test/                         Tests
ignition/                     Despliegue
```

## El launchpad de tokens

Cualquiera puede crear un lanzamiento llamando a `Launchpad.createLaunch`. Cada lanzamiento despliega un token nuevo y un contrato de venta (`TokenSale`) que recibe todo el supply.

### Las tres reglas

Son las que el front promete en la página Launchpad, y las hace cumplir el contrato, no el equipo:

1. **La liquidez la gestiona el contrato.** Lo recaudado va del contrato de venta al exchange en una sola transacción. El creador nunca lo toca.
2. **La liquidez queda bloqueada.** Los tokens del pool se envían a una dirección que nadie controla (`0x…dEaD`), así que la liquidez no se puede retirar nunca.
3. **El creador se queda como máximo con el 1% del supply.** Un lanzamiento que pida más no se puede crear.

### Reparto del supply

| Parte | Cuánto |
|---|---|
| Creador | Lo que elija, hasta el 1% |
| Venta | La mitad del resto |
| Liquidez | La otra mitad |

Lo que no se vende se quema, junto con su parte de la reserva de liquidez.

### Ciclo de una venta

La venta es a precio fijo, en la moneda nativa de la cadena. El precio sale de dividir el máximo a recaudar (`hardCap`) entre los tokens en venta.

| Estado | Qué pasa |
|---|---|
| `Upcoming` | Aún no ha llegado `startTime` |
| `Live` | Se aceptan contribuciones (`contribute`, o enviando moneda nativa al contrato). Lo que pase del `hardCap` se devuelve en el momento |
| `Succeeded` | Se alcanzó el `hardCap`, o llegó `endTime` con al menos el `softCap`. Cualquiera puede llamar a `finalize` |
| `Finalized` | El token está listado al mismo precio de la venta. Cada contribuyente retira sus tokens con `claim` |
| `Failed` | Llegó `endTime` sin alcanzar el `softCap`. No se lista nada y cada contribuyente recupera todo con `refund` |

### Qué puede hacer la plataforma

La dueña del `Launchpad` solo puede cambiar la comisión de los lanzamientos futuros (nunca por encima del 5% de lo recaudado) y la dirección que la cobra. No tiene ningún poder sobre un lanzamiento ya creado ni sobre sus fondos, y no puede pausar ni cancelar ventas.

### Límites de un lanzamiento

- Supply de hasta 10^15 tokens, con 18 decimales.
- La venta empieza como mucho 90 días después de crearse y dura como mucho 30 días.
- `softCap` mayor que cero y no mayor que `hardCap`.

## Despliegue

El `Launchpad` se despliega una vez por cadena, con el exchange y la moneda nativa envuelta de esa cadena:

1. Copia `ignition/parameters/example.json` a un archivo por red y rellénalo. `dexFactory` es la fábrica de pares del exchange (Uniswap V2, PancakeSwap V2 u otro compatible) y `weth` la moneda nativa envuelta. **Toma las dos direcciones de la documentación oficial del exchange**; una dirección equivocada dejaría la liquidez de todos los lanzamientos en el contrato equivocado.
2. Guarda la URL del nodo y la clave de despliegue, cifradas: `npx hardhat keystore set SEPOLIA_RPC_URL` y `npx hardhat keystore set DEPLOYER_PRIVATE_KEY`.
3. Despliega: `npx hardhat ignition deploy ignition/modules/Launchpad.ts --network sepolia --parameters ignition/parameters/sepolia.json`.

Las redes configuradas están en `hardhat.config.ts`: `sepolia`, `bscTestnet` y `robinhoodTestnet`.

## Pendiente antes de una red real

- Probar contra un Uniswap V2 real (en un fork o en testnet). Los tests usan un doble que imita cómo el par calcula la liquidez, pero no es el contrato real.
- Confirmar qué exchange compatible con Uniswap V2 existe en Robinhood Chain.
- Auditoría externa.
