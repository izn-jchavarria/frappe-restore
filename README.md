# iZone Enterprise · Restauración

Gestor por menú, escrito en Bash, que **restaura** respaldos de instancias
**Frappe / ERPNext** desde los destinos donde los deja
[`frappe-backup`](https://github.com/izn-jchavarria/frappe-backup):

- **Unidad de Red (CIFS/SMB)** — típicamente un NAS Synology. Se monta en solo
  lectura o, si el servidor no puede montar (un contenedor LXC sin
  privilegios), se lee con `rclone` sin montar nada
- **Google Drive** — vía `rclone`

Es la pieza inversa del gestor de respaldos, en un repositorio aparte. Ninguno
de los dos necesita al otro para funcionar, pero cuando conviven en el mismo
servidor este gestor reconoce los trabajos de respaldo ya configurados y
reutiliza su montaje y sus credenciales.

**Archivo único:** `frappe-restore.sh`, sin dependencias más allá de Bash 4,
`cifs-utils`, `smbclient` y `rclone`, que el propio gestor instala. Para leer
el NAS sin montarlo hace falta rclone v1.60 o mayor; si el del sistema es más
viejo, el gestor ofrece instalar una copia oficial verificada solo para eso.

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
| Punto de montaje propio (solo red por CIFS) | `/mnt/izn-stg-01-restore-staging-diario` |
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

Si el trabajo de respaldo envía al NAS por rclone (servidores que no pueden
montar), el origen heredado se lee también por rclone, con el mismo servidor,
recurso, credenciales y binario de rclone.

### Cuando el servidor no puede montar: rclone sin montaje

Un contenedor LXC sin privilegios (habitual en Proxmox) no puede montar
carpetas de red: `mount` responde `error(1): Operation not permitted` aunque
usuario, contraseña y ruta estén bien. El asistente lo detecta solo y lee el
NAS con rclone, sin montar nada y sin tocar `/etc/fstab`:

- Si el equipo es un contenedor sin privilegios, ni intenta montar. Si no lo
  es, prueba CIFS en solo lectura y pasa a rclone solo si el montaje falla con
  `error(1)`.
- Antes de crear el trabajo prueba la lectura: lista el origen y lee el
  `SHA256SUMS` del respaldo más reciente. Solo lee; nunca escribe en el NAS.
- La contraseña sigue solo en el `.cred`: no se escribe en la configuración
  de rclone.

---

## Qué hace cada restauración

1. Toma el **candado** del trabajo y del sitio: si otra restauración del mismo
   trabajo, o sobre el mismo sitio, sigue en curso, esta no corre (código 7).
2. Monta o abre el origen y **elige el respaldo**: el más reciente, o el que se
   indique. Solo puede elegir uno que el listado ofrezca: las carpetas
   `<hora>.subiendo.<trabajo>`, que el gestor de respaldos todavía está
   enviando, nunca se ofrecen ni se restauran.
3. Si es automática y ese respaldo **ya se restauró antes**, termina sin tocar
   nada. Un trabajo cada cuatro horas sobre respaldos diarios no repite trabajo
   ni riesgo.
4. Comprueba que haya **espacio en disco** antes de traer nada.
5. Trae la carpeta a `/var/tmp/<job>` (no a `/tmp`: un respaldo con adjuntos
   pesa varios GB).
6. **Verifica que llegó íntegro**, con el sitio todavía en línea:
   - el `SHA256SUMS` del respaldo: lo que llegó es idéntico a lo que el gestor
     de respaldos verificó y envió;
   - el volcado abre y llega hasta el final (un volcado cortado produce un `.gz`
     válido, así que `gzip -t` solo no basta);
   - cada `tar` de adjuntos se puede leer.

   Si algo falla aquí, termina con código 6: el sitio **no se toca** y ni
   siquiera entra en mantenimiento. Los respaldos sin `SHA256SUMS` (anteriores
   a la 2.4.0 del gestor de respaldos) se aceptan con aviso, o se rechazan si
   así se indica en las opciones del trabajo.
7. Si está activado, **respalda el sitio destino** con `bench backup --with-files`
   y guarda esa copia fuera de la carpeta de respaldos del sitio, para que el
   gestor de respaldos no se la lleve al NAS. Conserva las últimas N.
8. Pone el sitio destino en **mantenimiento** y ejecuta `bench restore` con la
   base de datos y los adjuntos. Solo ese sitio: el servidor de origen nunca
   se toca, porque del NAS o del Drive solo se lee.
9. Aplica lo posterior: `bench migrate`, programador de tareas, silenciar el
   correo saliente, contraseña de Administrator.
10. Saca el sitio de mantenimiento, anota el estado y vacía el temporal.

Si `bench restore` falla, el log dice dónde quedó el respaldo de seguridad (si
estaba activado) y el estado **no** se actualiza: el siguiente intento vuelve a
probar.

---

## Lo que evita que esto salga mal

- **El recurso de red se monta en solo lectura** cuando el montaje es propio, y
  por rclone solo se lee. Un error del servidor no puede alterar ni borrar los
  respaldos del NAS. Las cuentas de Drive nuevas se conectan con permiso
  `drive.readonly`.
- **Solo se restaura un respaldo íntegro**: huellas SHA256, volcado completo y
  adjuntos legibles, comprobados antes de tocar el sitio.
- **Nunca un respaldo a medias**: las carpetas `.subiendo` del gestor de
  respaldos no se ofrecen ni se aceptan con `--ruta`.
- **Una restauración a la vez** por trabajo y por sitio.
- **Respaldo de seguridad antes de cada restauración**, desactivado por defecto
  y activable en las opciones del trabajo. Si está activado y no se puede
  hacer, no se restaura.
- **Confirmación** (s/n) que muestra el respaldo y el sitio antes de cualquier
  restauración manual.
- **Prueba en seco** (`--simular`): trae el respaldo, comprueba que llegó
  íntegro y termina sin tocar el sitio.
- **Los trabajos se actualizan solos**: al abrir una versión nueva del gestor,
  el script de cada trabajo se regenera si cambió su código, y se reemplaza de
  una sola vez para no cortar una restauración en curso.

---

## El script de cada trabajo

El gestor genera un script por trabajo que lee su `.conf` en tiempo de
ejecución. Cambiar un valor desde el menú no lo regenera: solo reescribe el
`.conf`. Al actualizar el gestor, el script se regenera solo si cambió su
código (`GEN_VERSION`). Se puede usar directamente:

```bash
/usr/local/bin/<host>-restore-<etiqueta>.sh                      # el más reciente, si hay uno nuevo
/usr/local/bin/<host>-restore-<etiqueta>.sh --listar             # respaldos disponibles, del más reciente al más antiguo
/usr/local/bin/<host>-restore-<etiqueta>.sh --ruta 17-september-2026/12-00
/usr/local/bin/<host>-restore-<etiqueta>.sh --ultimo --forzar    # ignora el estado
/usr/local/bin/<host>-restore-<etiqueta>.sh --simular            # sin tocar el sitio
```

Códigos de salida: `0` correcto · `1` no se pudo preparar la restauración ·
`2` uso incorrecto · `4` falló `bench restore` · `5` restauró pero falló
`bench migrate` · `6` el respaldo no llegó íntegro (el sitio no se tocó) ·
`7` otra restauración de ese trabajo o sobre ese sitio sigue en curso.

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

