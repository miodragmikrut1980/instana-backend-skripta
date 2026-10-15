Primeri JSON fajlova za test-config-file.sh
Tajne u fajlovima su lažne test vrednosti (test-*-0000).

single-gcp-online-full.json
  Every value valid, secrets embedded (fake test values). Expect: zero prompts until 'Start now?'.

single-gcp-online-partial.json
  Missing BASE_DOMAIN, versions, SSH_SOURCE_CIDR; empty secrets. Expect: only those asked (secrets masked), nothing else.

single-gcp-invalid-values.json
  Five invalid values. Expect: one 'warn ... invalid' line per key, then the normal prompt; invalid value NOT offered as default.

single-gcp-provider-aliases.json
  Only PROVIDER_* names. Expect: provider_normalize_params fills GCP_*; zero prompts.

single-gcp-alias-conflict.json
  GCP_ZONE=europe-west6-b vs PROVIDER_LOCATION=europe-west6-a. Expect: warn with both values + choice prompt (b / a / enter another); without a terminal it is listed as a problem.

single-gcp-unknown-key.json
  Typo TENNANT_NAME. Expect: warn 'unknown key ... did you mean TENANT_NAME?', key ignored, TENANT_NAME asked.

single-gcp-legacy-no-provider.json
  No PROVIDER key. Expect: defaults to gcp, shown in the plan; zero prompts.

single-gcp-custom-size.json
  Custom size above production minimum. Expect: accepted; machine type derived from CPU/RAM.

single-gcp-custom-size-too-small.json
  16/64 below production minimum 28/112. Expect: warn + re-ask CPU and RAM (collect_cpu_ram).

three-gcp-size-large.json
  Three-node with SIZE=large. Expect: warn 'three-node uses a fixed size; ignoring', size=small; no die later in prepare_multinode_lab.

three-gcp-duplicate-names.json
  NODE1_NAME == NODE2_NAME. Expect: warn + re-ask NODE2_NAME.

three-ssh-full.json
  Existing hosts, full disk table. Expect: zero prompts until 'Start now?'; no SSH_SOURCE_CIDR/size/network asked.

single-ssh-bad-disk-and-gcp-key.json
  DISK_DEV_DATA=/dev/sdb (not by-id) and a GCP key on the ssh provider. Expect: warn + re-ask DISK_DEV_DATA; 'skip GCP_PROJECT ignored for provider ssh'.

single-gcp-airgapped-existing.json
  Air-gapped with existing package. Test replaces __ARCHIVE__ with the fake archive path. Versions come from the package; the versions in the file are listed as 'skip ... ignored'.

single-gcp-airgapped-missing-archive.json
  Archive path does not exist. Expect: warn + the existing air-gapped source menu.

single-gcp-secrets-only-download.json
  Only DOWNLOAD_KEY embedded. Expect: agent, sales, admin asked masked; no secret value in output, log or .install-config.json; test sets mode 644 first and expects warn + 600.

bad-schema-version.json
  schema_version 2. Expect: re-ask path in the import screen (or die_with_steps with --config).

bad-schema-name.json
  Wrong schema name. Expect: same as bad-schema-version.

bad-non-string-values.json
  Numbers instead of strings. Expect: schema check fails (all values must be strings).

invalid-json.json
  Truncated JSON. Expect: 'File is not valid JSON (jq: ...)' and re-ask path (die_with_steps with --config).

Non-tty: any partial file with --config and </dev/null -> die_with_steps listing the missing/invalid keys.
