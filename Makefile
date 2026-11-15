PYTHON ?= python3
SHELLCHECK ?= shellcheck
NODE ?= node

SHELL_SCRIPTS := build.sh utils.sh add-app.sh build-termux.sh $(wildcard .github/scripts/*.sh)
CONFIGS := $(wildcard configs/*.toml)

.PHONY: site preview check clean

site:
	$(PYTHON) scripts/generate_site.py

preview: site
	$(PYTHON) -m http.server -d site 8000

check:
	@for file in $(SHELL_SCRIPTS); do bash -n "$$file" || exit 1; done
	$(SHELLCHECK) -S warning $(SHELL_SCRIPTS)
	$(PYTHON) -m compileall -q scripts
	$(NODE) --check site/app.js
	$(PYTHON) scripts/config_style.py --check $(CONFIGS)
	$(PYTHON) scripts/validate_configs.py
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
		$(PYTHON) scripts/generate_site.py --offline --output "$$tmp/data.json" && \
		$(PYTHON) scripts/check_site_data.py "$$tmp/data.json"
	$(PYTHON) scripts/check_project_links.py

clean:
	rm -rf build temp site/apps site/data.json build.md release_notes.md config.json scripts/__pycache__
