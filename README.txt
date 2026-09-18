Instana GCP lab v0.5.8 — input never aborts without confirmation
CURRENT: read IZMENE_v0.5.8.txt, IZMENE_v0.5.7.txt and IZMENE_v0.5.6.txt first.

The installer now shows a 12-phase checklist, explains every phase before it
changes the VM or GCP project, displays overall completion percentage, and
records completed phases in .install-state.json. Resource validation remains
authoritative: a saved visual checkpoint never bypasses resume verification.

Use ./install.sh for a new deployment. Use ./install.sh --resume in the same
deployment folder when the selected topology supports continuation.
Legacy v0.3.x resources are not adopted. Uncertain stanctl up execution
requires inspection; never starts a second remote installer blindly.

Na upravljackoj Ubuntu VM v NOVEM folderu:
chmod +x *.sh
./install.sh --dry-run
Po pregleda plana stvarno pokretanje: ./install.sh

Izaberi three-node, online, SMALL, Ubuntu 24.04 ili 22.04.
Koristi tri NOVA VM naziva i NOVI domen, npr. instana-lab.mikrut.rs.
Postojeci single-node DNS ne menjati. Novi domen, UI i acceptore usmeri na
external IP node0. DNS nije automatizovan. Instana production install type
je obavezan za multi, ali ovo je interno LAB okruzenje.

IBM small minimum: 12 CPU/48 GB po nodu. GCP mapping: n2-standard-16
(16 CPU/64 GB po nodu), ukupno 48 CPU/192 GB. Boot SSD270 GB po nodu;
objects1000 na node0, data500/metrics1000/analytics1200 na node1.
Ukupno provisioned4510 GB. Fizicka izolacija i sustained I/O nisu
sertifikovani; ne predstavlja produkcionu preporuku.

Posebni firewall/tag za ovaj deployment; CPU flags; OS bootstrap; kernel;
boot ID provera restarta; root SSH node0->sva tri privateIP; UFW; blank disk
format/mount; stanctl na node0; multi IP redosled backend/datastore/other;
provera 3 Ready nodes. Pod check je nasledjen osnovni, ne kompletan health.
Na novim multi VM OS Login je iskljucen radi root key SSH. Ako je to
zabranjeno organizacionom politikom, STOP; ne zaobilaziti politiku.

Pamti parametre mode600 bez tajni. Svaki deployment u zasebnom folderu.
State belezi resurse/checkpoints, ali MULTINODE RESUME NIJE implementiran.
Posle greske ne pokretati naslepo ponovo; sacuvati log/state za pregled.
destroy.sh cita state iz istog foldera; brise trajno uz eksplicitnu potvrdu.

Air-gapped (v0.5.7): na bastion masini sa internetom napravi paket komandom
'stanctl air-gapped package' (trazi download i sales key, bira backend
verziju). Skripti se daje SAMO instana-airgapped.tar.gz; stanctl binarni fajl
je vec u arhivi, .deb paket vise nije potreban. Skripta lokalno cita verzije
iz arhive i prikazuje ih u planu. Air-gapped tok i dalje NIJE potvrdjen
stvarnim deploymentom; resume za air-gapped nije podrzan.

Single-node kernel skip jos ostaje iz working kopije i nije genericki
installer za novu single VM.
Stari v0.2.2 tekst opisuje prethodni release, ovaj README ima prednost.

Testovi: bash syntax, 4 mock dry-run toka, config persistence tests,
test-input-reask.sh (ponovno pitanje umesto prekida).
Stvarni GCP deploy NIJE testiran. IBM docs PDF145–154 i169–172;
stanctl flags pregledani iz dostavljenog source. Confidential IBM source
i PDF se NE distribuiraju u ZIP-u.
