# iZone Enterprise · Restauración

Gestor por menú, escrito en Bash, que **restaura** respaldos de instancias
**Frappe / ERPNext** desde los destinos donde los deja
[`frappe-backup`](https://github.com/izn-jchavarria/frappe-backup):

- **Unidad de Red (CIFS/SMB)** — típicamente un NAS Synology
- **Google Drive** — vía `rclone`

Es la pieza inversa del gestor de respaldos, en un repositorio aparte. Ninguno
de los dos necesita al otro para funcionar, pero cuando conviven en el mismo
servidor este gestor reconoce los trabajos de respaldo ya configurados y
reutiliza su montaje y sus credenciales.

**Archivo único:** `frappe-restore.sh`, sin dependencias más allá de Bash 4,
`cifs-utils`, `smbclient` y `rclone`, que el propio gestor instala.

## Instalación

```bash
wget -qO frappe-restore.sh https://github.com/izn-jchavarria/frappe-restore/releases/latest/download/frappe-restore.sh && sudo bash frappe-restore.sh
```

El enlace `releases/latest/download/` apunta siempre a la release más reciente,
siempre que el asset conserve el nombre `frappe-restore.sh`.

---

## Para qué sirve

Dos usos, con el mismo mecanismo:

- **Mantener una copia al día.** Un servidor de pruebas o capacitación que cada
  madrugada toma el último respaldo de producción y se refresca solo.
- **Recuperarse.** Elegir un respaldo concreto de la lista y restaurarlo sobre
  el sitio, a mano, cuando hace falta volver atrás.

---

## El trabajo de restauración

Un **trabajo** es un origen de respaldos más un sitio destino. Tiene su propia
etiqueta, y de ella salen todos sus nombres de archivo. Puede quedar programado
o guardarse solo para ejecutarlo a mano.

Con `hostname -s` = `izn-stg-01` y etiqueta `staging-diario`:

| Elemento | Ruta |
|---|---|
| Script | `/usr/local/bin/izn-stg-01-restore-staging-diario.sh` |
| Configuración | `/etc/izone-restore/izn-stg-01-restore-staging-diario.conf` |
| Credenciales de base de datos | `/etc/izone-restore/izn-stg-01-restore-staging-diario.dbcred` (chmod 600) |
| Credenciales del recurso de red | `/etc/izone-restore/izn-stg-01-restore-staging-diario.cred` (chmod 600) |
| Estado | `/etc/izone-restore/izn-stg-01-restore-staging-diario.state` |
| Log | `/var/log/izone-restore/izn-stg-01-restore-staging-diario.log` |
| Respaldos de seguridad | `/var/backups/izone-restore/izn-stg-01-restore-staging-diario/` |
| Punto de montaje propio | `/mnt/izn-stg-01-restore-staging-diario` |
| Bloque de cron | `# >>> izone-restore:<job> >>>` … `# <<< izone-restore:<job> <<<` |
| Línea de fstab | precedida por `# izone-restore:<job>` |

Los prefijos `izone-restore` y `izone-backup` no se cruzan: los dos gestores
pueden convivir en un servidor sin pisarse ni en `/etc/fstab` ni en el crontab.

### Orígenes heredados

Si el servidor ya respalda hacia un NAS o hacia Drive, el asistente ofrece esos
destinos como origen. Al elegir uno se reutilizan su punto de montaje, sus
credenciales y su cuenta de rclone: no se duplica nada en `/etc/fstab`. El
trabajo recuerda de cuál lo heredó y el diagnóstico avisa si ese trabajo de
respaldo desaparece.

Si no hay ninguno —el caso de un servidor de pruebas que nunca respaldó nada—
el asistente configura el origen desde cero.

---

## Qué hace cada restauración

1. Monta el origen si hace falta y **elige el respaldo**: el más reciente, o el
   que se indique.
2. Si es automática y ese respaldo **ya se restauró antes**, termina sin tocar
   nada. Un trabajo cada cuatro horas sobre respaldos diarios no repite trabajo
   ni riesgo.
3. Comprueba que haya **espacio en disco** antes de traer nada.
4. Trae la carpeta a `/var/tmp/<job>` (no a `/tmp`: un respaldo con adjuntos
   pesa varios GB).
5. **Verifica** que exista el volcado y que no esté dañado (`gzip -t`). Si algo
   falla aquí, el sitio no se toca.
6. **Respalda el sitio destino** con `bench backup --with-files` y guarda esa
   copia fuera de la carpeta de respaldos del sitio, para que el gestor de
   respaldos no se la lleve al NAS. Conserva las últimas N.
7. Pone el sitio en **mantenimiento** y ejecuta `bench restore` con la base de
   datos y los adjuntos.
8. Aplica lo posterior: `bench migrate`, programador de tareas, silenciar el
   correo saliente, contraseña de Administrator.
9. Saca el sitio de mantenimiento, anota el estado y vacía el temporal.

Si `bench restore` falla, el log dice dónde quedó el respaldo de seguridad y el
estado **no** se actualiza: el siguiente intento vuelve a probar.

---

## Lo que evita que esto salga mal

- **El recurso de red se monta en solo lectura** cuando el montaje es propio.
  Un error del servidor no puede alterar ni borrar los respaldos del NAS. Las
  cuentas de Drive nuevas se conectan con permiso `drive.readonly`.
- **Respaldo de seguridad antes de cada restauración**, activado por defecto.
  Si no se puede hacer, no se restaura.
- **Confirmación escribiendo el nombre del sitio** antes de cualquier
  restauración manual.
- **Aviso si el sitio destino es el mismo que respalda este servidor.** Es lo
  correcto para recuperarse de un desastre y un error grave si lo que se quería
  era refrescar otro sitio; el asistente obliga a confirmarlo por escrito.
- **Prueba en seco** (`--simular`): trae el respaldo, lo verifica y termina sin
  tocar el sitio.

---

## El script de cada trabajo

El gestor genera un script por trabajo que lee su `.conf` en tiempo de
ejecución. Cambiar un valor desde el menú no lo regenera: solo reescribe el
`.conf`. Se puede usar directamente:

```bash
/usr/local/bin/<host>-restore-<etiqueta>.sh                      # el más reciente, si hay uno nuevo
/usr/local/bin/<host>-restore-<etiqueta>.sh --listar             # respaldos disponibles, del más reciente al más antiguo
/usr/local/bin/<host>-restore-<etiqueta>.sh --ruta 17-september-2026/12-00
/usr/local/bin/<host>-restore-<etiqueta>.sh --ultimo --forzar    # ignora el estado
/usr/local/bin/<host>-restore-<etiqueta>.sh --simular            # sin tocar el sitio
```

Códigos de salida: `0` correcto · `1` no se pudo preparar la restauración ·
`4` falló `bench restore` · `5` restauró pero falló `bench migrate`.

Los respaldos se ordenan por la **fecha real** de la carpeta, no por su nombre:
el nombre lleva el mes en letras y depende del idioma del servidor que hizo el
respaldo.

---

## Requisitos y advertencias

- Se ejecuta como **root** (monta, escribe en `/etc` y programa cron), pero
  `bench` se ejecuta siempre con el **usuario propietario del bench**, que el
  asistente detecta y ofrece.
- `bench restore` necesita la contraseña de **root del motor de base de datos**.
  En una restauración programada nadie puede escribirla, así que se guarda en el
  archivo `.dbcred` con permisos 600. Se pasa a `bench` como argumento, de modo
  que es visible en la lista de procesos mientras dura la restauración: es el
  mecanismo que ofrece `bench` y conviene tenerlo presente en servidores con
  varios usuarios con acceso de shell.
- El nombre exacto de esa opción cambió entre versiones de bench
  (`--db-root-password` / `--mariadb-root-password`). El asistente lo consulta
  al crear el trabajo y lo guarda en el `.conf`.
- **Las apps instaladas deben coincidir** entre el servidor de origen y el de
  destino. Si no, `bench migrate` falla: el sitio queda restaurado y el trabajo
  termina con código 5.
- Un sitio restaurado llega con la configuración del sitio de origen: sus
  cuentas de correo, sus tareas programadas y sus usuarios. Para una copia de
  pruebas conviene **desactivar el programador** y **silenciar el correo
  saliente**; ambas cosas están en el asistente.

