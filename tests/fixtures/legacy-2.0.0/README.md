# A backup set written by f5-cert-push 2.0.0

`20260930-162806/` was produced by the **2.0.0** `R_BACKUP` code itself (from the 2.0.0 release in this
repository's history), against a stand-in filestore. `tests/regress.sh` uses it to check that 2.1.x still
accepts and restores a genuine 2.0.0 set, and refuses one whose restore script was altered.

The certificates and the private key in it are **throwaway, self-signed test material** created only for
this fixture. They protect nothing and must never be used for anything else.
