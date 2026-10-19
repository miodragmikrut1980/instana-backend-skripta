Instana GCP lab v0.7.0 — UX v2 ("<" goes back, detected defaults, hosts first); install on existing hosts over SSH (PROVIDER ssh); parameters from a JSON file (--config, config-generator.html); provider layer (GCP behind providers/); backend version chosen first; resilient installer
CURRENT: read IZMENE_v0.7.0.txt and IZMENE_v0.6.1.txt first, then the older IZMENE files for details.

QUICK START — POKRETANJE NA UPRAVLJACKOJ VM
===========================================
Preduslovi na VM: gcloud (prijavljen na projekat), git, jq. Skripta sama
ponudi screen (i instalira ga) da instalacija prezivi prekid SSH veze.

1) PRVI PUT na VM (skripta jos ne postoji lokalno):
     git clone https://github.com/miodragmikrut1980/instana-backend-skripta.git
     cd instana-backend-skripta
     ./install.sh
   Pravo izvrsavanja dolazi iz repoa; chmod nije potreban.

2) SKRIPTA VEC POSTOJI na VM (osvezi na poslednju verziju, pa pokreni):
     cd ~/instana-backend-skripta
     git checkout -- . && git pull origin main
     ./install.sh
   (git checkout -- . vraca eventualno obrisane/izmenjene fajlove pre pull-a;
   ako install.sh javi da fali neki .sh fajl, ispise istu ovu komandu.)
   Od v0.7.0 skripta treba i folder providers/ (dolazi istim git pull-om);
   kopiras li skriptu rucno, kopiraj ceo folder, ne samo *.sh.

2b) SVEZ POCETAK kad folder vec postoji (brise se lokalni state, config i
    izvestaj poslednje instalacije — GCP resursi ostaju netaknuti; ako
    postoje, kasnije ih brises kroz meni "Clean up a lab"):
     cd ~ && rm -rf ~/instana-backend-skripta
     git clone https://github.com/miodragmikrut1980/instana-backend-skripta.git
     cd instana-backend-skripta && ./install.sh
    Uvek pisati punu putanju (rm -rf ~/instana-backend-skripta), nikad rm -r *.

3) POSLE PREKIDA VEZE dok instalacija radi:
     cd ~/instana-backend-skripta && ./install.sh
   Skripta prepozna aktivnu screen sesiju i ponudi "reattach". Rucno:
   screen -ls, pa screen -d -r <ime>.

4) OSTALE KOMANDE:
     ./install.sh --report           izvestaj poslednje instalacije (UI URL,
                                     IP, /etc/hosts linije); isto u meniju
     ./install.sh --dry-run          samo plan, nista se ne kreira
     ./install.sh --resume           nastavak prekinutog deploymenta (online i air-gapped)
     ./install.sh --destroy          brisanje resursa iz ovog foldera
     ./install.sh --destroy --dry-run  pregled brisanja
     ./install.sh --help
   Start meni: 1) Install on new Google Cloud VMs, 2) Install on existing
   hosts (SSH; bilo koji cloud ili on-prem), 3) Dry-run (pita: GCP ili
   postojeci hostovi; 0 = nazad), Clean up a lab, Exit; Enter = 1.
   ./install.sh --dry-run u terminalu isto pita cilj, osim ako je vec poznat
   (zapisan u folderu, INSTANA_PROVIDER ili --config).
   Bez state fajla meni nudi "Clean up a lab": skripta izlista labove
   projekta (samo citanje): three-node labove po labeli instana-lab-id i
   single-node VM-ove sa diskovima <ime>-analytics/-metrics/-objects/-data,
   sa statusom, datumom, diskovima i napomenom o trosku (i zaustavljen VM
   placa diskove). Upravljacka masina se nikad ne nudi. Izaberes lab ->
   tacan spisak sta se brise -> kucana potvrda DELETE <projekat>/<zona>
   (pregled sa --dry-run je bez potvrde i nista ne brise). n = trazi VM po
   imenu, < = drugi projekat.

5) PARAMETRI IZ FAJLA UMESTO PITANJA (config-generator.html, --config):
   a) Otvori config-generator.html (u ovom folderu) u browseru na svom
      racunaru; radi i bez interneta. Popuni sta znas (prazno = skripta pita).
      Kljucevi: podrazumevano ih skripta pita sakriveno; mogu i u fajl
      (fajl je onda samo za vlasnika, 600) ili kroz promenljive okruzenja
      INSTANA_DOWNLOAD_KEY / INSTANA_AGENT_KEY / INSTANA_SALES_KEY /
      INSTANA_ADMIN_PASSWORD.
   b) Prebaci fajl na VM: dugme "Copy as paste-in command" pa paste u
      terminal VM-a (upise ~/instana-backend-skripta/instana-config-....json),
      ili "Download file" pa gcloud compute scp.
   c) Pokreni (prvo plan, pa pravo; zameni IME imenom svog fajla):
        ./install.sh --config instana-config-IME.json --dry-run
        ./install.sh --config instana-config-IME.json
      Ili bez --config: u meniju "How do you want to provide the deployment
      parameters?" izaberi "import them from a JSON file" i upisi putanju.
   Svaka vrednost iz fajla prolazi istu proveru kao kucani odgovor. Na
   pocetku tabela: ok (uzeto iz fajla) / ask (fali ili ne valja, sa
   razlogom) / skip (ne vazi za ovaj deployment). Pitaju se samo ask
   vrednosti. Bez terminala (npr. ssh komanda, cron) skripta odmah stane i
   izlista SVE vrednosti koje fale ili ne valjaju, sa primerom ispravne.
   I potpun fajl bez terminala stane na planu: start uvek trazi Y
   (npr. echo y | ./install.sh --config instana-config-IME.json).
   Na planu: Y = start, E = promeni jednu vrednost (plan se ponovo pokaze),
   S = sacuvaj parametre u novi fajl (bez kljuceva) i stani, N = odustani.
     ./install.sh --export-config [fajl]   parametri sacuvani u ovom folderu
                                           (.install-config.json) kao takav fajl
   Meni "Where do the answers come from?" (1 = kucaj odgovore, Enter = 1) se
   prikazuje samo kad ovde ima sta da se uveze (instana-config*.json u folderu
   ili sacuvani odgovori); inace pitanja krecu odmah, uz jedan red sa savetom
   za --config (vidi 6).
   Three-node ne pita velicinu (uvek small, 3x n2-standard-16).

6) TOK PITANJA (UX v2) - NAZAD, PREDLOZI, PLAN:
   - NAZAD: u listama stavka "0) ← back" (kucaj 0). U tekstualnim pitanjima
     "[← = back]": strelica levo na praznom odgovoru upise "<", Enter vraca
     na prethodno pitanje (Backspace ponistava). "<" + Enter radi svuda, i
     bez terminala. Raniji odgovori ostaju kao Enter; promenjen odgovor ponovo
     pita samo ono sto od njega zavisi. Blokovi bez nazad (paket, liste
     verzija, hostovi iz fajla) se preskacu; njihove vrednosti menja E na planu.
   - Pomoc: iznad pitanja je jedan kratak red; "?" + Enter prikazuje duze
     objasnjenje. ./install.sh --verbose (ili INSTANA_VERBOSE=1) uvek sve.
   - Boje samo u terminalu i bez NO_COLOR; logovi su uvek cist tekst.
   - Liste imaju podrazumevani izbor: "Select [1-2, Enter = 1]".
   - GCP: projekat, zona (region iz zone), mreza i SSH CIDR su JEDAN blok
     "Use detected" (iz gcloud-a i ove masine): Enter = prihvati, c = promeni.
     Ako javna IP ove masine nije otkrivena, 0.0.0.0/0 se ne prihvata Enterom.
     Ubuntu verzija i velicina masine se ne pitaju (24.04, minimum za tip);
     menja ih E na planu, kao i "kubectl without sudo" (podrazumevano no).
   - Ime VM-a se proverava odmah (da li vec postoji u zoni).
   - Plan je grupisan: Where / What / Access / Resources. Y = start,
     E = promeni vrednost, S = sacuvaj u fajl, N ili Enter = odustani.
   - Na kraju instalacije se nista ne pita: /etc/hosts linije koriste javnu
     IP node 0 kad je poznata.
   - Ponuda za screen dolazi posle menija i samo za install/resume.
   - Odustajanje (potvrdjeno) zavrsava sa exit 0: "Nothing was created or
     changed".

7) INSTALACIJA NA POSTOJECE HOSTOVE (PROVIDER ssh, bez GCP-a):
   Skripta se poveze SSH-om na 1 ili 3 Ubuntu hosta koje vec imas (kod
   korisnika, on-prem, bilo koji cloud). Ne pravi, ne brise i bez pitanja ne
   restartuje hostove. Pokretanje:
     INSTANA_PROVIDER=ssh ./install.sh --dry-run      (plan, nista se ne menja)
     INSTANA_PROVIDER=ssh ./install.sh
   ili iz fajla: config-generator.html -> "Existing hosts (SSH)", pa --config.
   Hostovi moraju imati: Ubuntu 22.04/24.04 x86_64; za single-node demo bar
   16 vCPU / 64 GB (production 28/112), three-node bar 12 vCPU / 48 GB po
   nodu; / od najmanje 100 GB (three-node: ispod 270 GB samo upozorenje);
   SSH korisnika sa sudo BEZ lozinke; po jedan prazan disk za svaki Instana
   direktorijum (single-node 4; three-node: node 0 objects, node 1 data/
   metrics/analytics); bez aktivnog firewalld i bez postojeceg k3s.
   Three-node: sshd mora da slusa i na portu 22 (stanctl multi-node).
   SSH kljuc sa lozinkom (passphrase) mora biti u ssh-agent-u:
     eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
   (skripta u terminalu jednom pokrene ssh-add; lozinku nikad ne cita/cuva).
   Tok (UX v2): prvo hostovi - lista pokrenutih VM-ova gcloud projekta (ime,
   interna i eksterna IP, zona, tip masine; upravljacka masina se nikad ne
   nudi) i Host unosi iz ~/.ssh/config, ili ukucane adrese (host:port za
   drugi port). 1 host = single-node, 3 hosta = three-node. Zatim skripta
   SAMA nadje prijavu (proba lokalne kljuceve x korisnike ubuntu i tvoj
   login, najvise 4 pokusaja) i ponudi je ("Enter = use this login"), odmah
   procita hostove (samo citanje) i pokaze tabelu provera. Svaka greska
   (nema odgovora, odbijen kljuc, promenjen host kljuc, sudo trazi lozinku,
   premali host...) daje meni: ponovo upisi adresu / izaberi sa liste /
   promeni prijavu / proveri ponovo / odustani - bez prekida, nista se ne
   gubi. Tip (demo/production) se predlaze iz CPU/RAM/diskova, diskovi se
   rasporede sami (Enter = prihvati, c = biraj sam), imena = imena hostova.
   Za online lab sa poznatom javnom IP domen se predlaze kao
   instana.<a-b-c-d>.sslip.io (samo predlog; nikad za air-gapped).
   Plan nabraja izmene na hostovima (kernel + RESTART, UFW, root SSH izmedju
   nodova, formatiranje praznih diskova) i potrebne mrezne veze (za GCP VM
   procita firewall pravila, samo citanje); JEDNO Y u terminalu odobrava
   sve (pamti se za --resume). Faze 3-5: provera hostova, diskova i portova.
   Svako zaustavljanje kaze sta je nadjeno i na kom hostu, zasto to
   blokira instalaciju, tacne komande za popravku i kako nastaviti.
   --destroy za ssh brise SAMO lokalni state ovog foldera; na hostovima
   ostaje sve (skripta ispise sta i kako se rucno uklanja).
   SSH pristup: pokreni instalaciju kao ISTI Linux korisnik koji je vlasnik
   kljuca (SSH_KEY_PATH); kljuc drugog korisnika na ovoj masini ne vazi.
   Hostovi u Google Cloud-u sa ukljucenim OS Login-om (metadata projekta
   enable-oslogin=TRUE) ignorisu ssh-keys iz metadata: na toj instanci
   postavi enable-oslogin=false, ili korisniku daj OS Login prava.
   Proba pre instalacije (mora proci bez lozinke):
     ssh -i <kljuc> -p <port> <korisnik>@<host> sudo -n true
   Ako folder vec ima deployment drugog providera (npr. stari GCP lab),
   skripta u terminalu ponudi: nastavi taj deployment, ili ga skloni u
   stranu (fajlovi se preimenuju, nista se ne brise) i kreni novi; za
   GCP lab koji vise ne treba prvo ./install.sh --destroy.

Ne klonirati repo unutar postojeceg klona (nastaje ugnjezdeni folder sa
odvojenim state fajlovima). Ne koristiti rm -r * bez pwd provere.

The installer now shows a 12-phase checklist, explains every phase before it
changes the VM or GCP project, displays overall completion percentage, and
records completed phases in .install-state.json. Resource validation remains
authoritative: a saved visual checkpoint never bypasses resume verification.

Started outside screen/tmux, install.sh offers to re-launch itself inside a
screen session (installing screen if needed) so a dropped SSH connection cannot
kill a running installation; reattach with 'screen -d -r <name>'.
Use ./install.sh for a new deployment. Use ./install.sh --resume in the same
deployment folder when the selected topology supports continuation.
Started without options from a terminal, install.sh shows a start menu:
install on new Google Cloud VMs / install on existing hosts (SSH, any cloud
or on-prem) / dry-run (asks which of the two) / resume, preview and delete
(if a deployment is recorded) / clean up a lab / exit; Enter = 1. ./install.sh --destroy (optionally with --dry-run) runs the
cleanup directly; destroy.sh still exists but need not be called by hand.
Without a state file the menu offers "Clean up a lab" instead: it lists the
labs of the project (instana-lab-id label groups and single-node VMs with
<vm>-analytics/-metrics/-objects/-data disks; never the control machine),
shows exactly what a picked lab consists of, and deletes only after
DELETE <project>/<zone> is typed (a --dry-run preview deletes nothing).
Legacy v0.3.x resources are not adopted. Uncertain stanctl up execution
requires inspection; never starts a second remote installer blindly.

Na upravljackoj Ubuntu VM v NOVEM folderu:
chmod +x *.sh
./install.sh --dry-run
Po pregleda plana stvarno pokretanje: ./install.sh

Izaberi three-node, online, Ubuntu 24.04 ili 22.04 (velicina je fiksna: small).
Koristi tri NOVA VM naziva i NOVI domen, npr. instana-lab.mikrut.rs.
Postojeci single-node DNS ne menjati. Novi domen, UI i acceptore usmeri na
external IP node0. DNS nije automatizovan. Instana production install type
je obavezan za multi, ali ovo je interno LAB okruzenje.

IBM small minimum: 12 CPU/48 GB po nodu. GCP mapping: n2-standard-16
CPU: IBM zahteva x86-64-v3 (AVX2/BMI2/FMA...); skripta to proverava na svakom nodu u fazi 6. n2-standard (Cascade Lake+) ispunjava; n1/e2 na starijim platformama ne.
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
State belezi resurse/checkpoints; --resume ponovo proverava svaki resurs (three-node online i air-gapped).
Posle greske ne pokretati naslepo ponovo; sacuvati log/state za pregled.
destroy.sh cita state iz istog foldera; brise trajno uz eksplicitnu potvrdu.

Air-gapped (v0.5.9): kad izaberes air-gapped, skripta objasni sta je paket
(instana-airgapped.tar.gz, pravi ga 'stanctl air-gapped package' na masini sa
internetom, sadrzi i stanctl binarni fajl, vise desetina GB) i ponudi meni:
1) postojeca arhiva na ovoj masini, 2) napravi paket sada OVDE (skripta sama
instalira stanctl iz Instana APT repoa i pokrene pakovanje; treba internet,
sudo, ~40 GB), 3) predji na online instalaciju, 4) otkazi. Verzije se citaju
iz arhive i prikazuju u planu. Air-gapped tok je POTVRDJEN stvarnim
deploymentom 18.09.2026 (single-node demo, paket napravljen opcijom 2 na
upravljackoj VM, stanctl 1.15.0 / backend 3.323.470-0, svih 12 faza).
Resume za air-gapped (single-node i three-node): paket se kopira u
/var/tmp/instana-airgapped.tar.gz na VM (preko .part imena, pa rename), pa
--resume posle prekida ne kopira ponovo desetine GB: postojeca kopija (ili
.part pune velicine) se uporedi SHA-256 sa lokalnom arhivom i koristi.
Import se ne ponavlja automatski; posle uspeha VM dobija marker
/var/lib/instana-airgap/imported, pa se zavrsen import (marker + tacna
stanctl verzija) ne radi ponovo. Pre kopiranja se trazi ~2x velicina paketa
+ 5 GB slobodno u /var/tmp. Ako je lokalna arhiva u medjuvremenu zamenjena
drugom verzijom, resume staje sa HOW TO RESOLVE.
Three-node air-gapped sada ide istim lab tokom kao online (3x n2-standard-16,
deployment identitet, resume; faza 6 i dalje koristi apt na nodovima);
end-to-end na GCP jos nije potvrdjen.

Single-node kernel skip jos ostaje iz working kopije i nije genericki
installer za novu single VM.
Stari v0.2.2 tekst opisuje prethodni release, ovaj README ima prednost.

Testovi: bash syntax, 4 mock dry-run toka, test-airgap-resume.sh, config persistence tests,
test-input-reask.sh (ponovno pitanje umesto prekida), test-config-file.sh (ulazni JSON fajl,
primeri u examples/).
Stvarni GCP deploy NIJE testiran. IBM docs PDF145–154 i169–172;
stanctl flags pregledani iz dostavljenog source. Confidential IBM source
i PDF se NE distribuiraju u ZIP-u.
