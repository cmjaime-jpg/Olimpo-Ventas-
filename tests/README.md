# Inventario 3.5

Pruebas DOM aisladas, sin sesión ni escrituras en Supabase:

```sh
npm install --prefix /tmp/olimpo-qa jsdom@31.0.1 --no-audit --no-fund
NODE_PATH=/tmp/olimpo-qa/node_modules node tests/inventario.cjs
```

Valida arranque de la aplicación, alertas, sugerencias sin duplicar productos, datos de compra, recepción parcial, decimales, alternativa manual del lector y limpieza al cerrar sesión.

También se verificó en una transacción SQL revertida: crear compra con decimales, recepción parcial y completa, reintentos idempotentes, rechazo de sobrerrecepción, actualización de costos, movimientos y denegación sin usuario. Los 76 productos se conservaron.

El historial comienza al activar el trigger; no reconstruye movimientos antiguos. La cámara usa BarcodeDetector y requiere HTTPS, permiso del usuario y navegador compatible. Falta validación física con el celular del usuario; navegadores no compatibles permiten ingreso manual.

Las exportaciones CSV incluyen inventario, compras y movimientos consultados. No se envían pedidos automáticamente al proveedor. La integración SII no fue modificada.
