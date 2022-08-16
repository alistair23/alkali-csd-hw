# -----------------------------------------------------------------------------
# Common settings -------------------------------------------------------------
# -----------------------------------------------------------------------------

ROOT_DIR = $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

DOCKER_TAG_NAME=hw:1.0
NVME_SPEC_NAME = NVM-Express-1_4-2019.06.10-Ratified.pdf

# Input settings -------------------------------------------------------------

BOARD ?= basalt
BAR_SIZE ?= 16MB
DOCKER_IMAGE_BASE ?= debian:bullseye
BUILD_DIR ?= $(ROOT_DIR)/build

# Input paths -----------------------------------------------------------------

THIRD_PARTY_DIR = $(ROOT_DIR)/third-party
REGGEN_DIR = $(ROOT_DIR)/third-party/registers-generator
VIVADO_COLOR_SCRIPT = $(ROOT_DIR)/vivado/tools/color_log.awk

# Output paths ----------------------------------------------------------------

BOARD_BUILD_DIR = $(BUILD_DIR)/$(BOARD)
CHISEL_BUILD_DIR = $(BOARD_BUILD_DIR)/chisel_project
SCALA_BUILD_DIR = $(BUILD_DIR)/scala
DOCKER_BUILD_DIR = $(BUILD_DIR)/docker
SBT_EXTRA_DIR = $(shell realpath --relative-to $(ROOT_DIR)/chisel $(SCALA_BUILD_DIR))

# Helpers ---------------------------------------------------------------------

DOCKER_TAG = $(DOCKER_IMAGE_PREFIX)$(DOCKER_TAG_NAME)

# -----------------------------------------------------------------------------
# All -------------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: all
all: vivado ## Build all

# Generate general and board-specific build directories -----------------------

$(BUILD_DIR):
	mkdir -p $@

$(BOARD_BUILD_DIR):
	mkdir -p $@

# -----------------------------------------------------------------------------
# Clean -----------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: clean
clean: ## Clean build artifacts
	$(RM) -r .Xil
	$(RM) -r $(BUILD_DIR)/

# -----------------------------------------------------------------------------
# Vivado ----------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: vivado
vivado: SHELL := /bin/bash ## Build vivado design
vivado: $(BOARD_BUILD_DIR)/project_vta/out/top.bit

$(BOARD_BUILD_DIR)/project_vta/out/top.bit: $(CHISEL_BUILD_DIR)/NVMeTop.v
$(BOARD_BUILD_DIR)/project_vta/out/top.bit: | $(BOARD_BUILD_DIR)
	@echo "Building for board: $(BOARD)"
	cd $(BOARD_BUILD_DIR) && \
		set -o pipefail && \
		$(ROOT_DIR)/vivado/build_project.sh $(BOARD_BUILD_DIR) vta $(BAR_SIZE) $(BOARD) 2>&1 \
		| awk -f $(VIVADO_COLOR_SCRIPT)

# -----------------------------------------------------------------------------
# Generate --------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: generate
generate: $(BUILD_DIR)/registers.json ## Generate register description in chisel
generate: $(SCALA_BUILD_DIR)/RegisterDefs.scala
generate: $(SCALA_BUILD_DIR)/CSRRegMap.scala

GIT_SHA = "$(shell git rev-parse --short HEAD)"

$(BUILD_DIR)/registers.json: $(REGGEN_DIR)/get_reg_fields.py
$(BUILD_DIR)/registers.json: $(REGGEN_DIR)/$(NVME_SPEC_NAME)
$(BUILD_DIR)/registers.json: | $(BUILD_DIR)
	$(REGGEN_DIR)/get_reg_fields.py $(REGGEN_DIR)/$(NVME_SPEC_NAME) -f $@

$(SCALA_BUILD_DIR):
	@mkdir -p $@

$(SCALA_BUILD_DIR)/RegisterDefs.scala: $(REGGEN_DIR)/get_reg_fields_chisel.py
$(SCALA_BUILD_DIR)/RegisterDefs.scala: $(BUILD_DIR)/registers.json
$(SCALA_BUILD_DIR)/RegisterDefs.scala: | $(SCALA_BUILD_DIR)
	$(REGGEN_DIR)/get_reg_fields_chisel.py $(BUILD_DIR)/registers.json -f --git-sha=$(GIT_SHA) $@

$(SCALA_BUILD_DIR)/CSRRegMap.scala: $(REGGEN_DIR)/get_reg_map_chisel.py $(REGGEN_DIR)/$(NVME_SPEC_NAME) | $(SCALA_BUILD_DIR)
	$(REGGEN_DIR)/get_reg_map_chisel.py $(REGGEN_DIR)/$(NVME_SPEC_NAME) -f --git-sha=$(GIT_SHA) $@

# -----------------------------------------------------------------------------
# Chisel ----------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: chisel
chisel: $(BUILD_DIR)/chisel_project/NVMeTop.v ## Generate verilog sources using chisel

$(CHISEL_BUILD_DIR):
	@mkdir -p $@

$(BOARD_BUILD_DIR)/chisel_project/NVMeTop.v: $(BUILD_DIR)/registers.json
$(BOARD_BUILD_DIR)/chisel_project/NVMeTop.v: $(SCALA_BUILD_DIR)/RegisterDefs.scala
$(BOARD_BUILD_DIR)/chisel_project/NVMeTop.v: $(SCALA_BUILD_DIR)/CSRRegMap.scala
$(BOARD_BUILD_DIR)/chisel_project/NVMeTop.v: | $(CHISEL_BUILD_DIR)
	OUTPUT_DIR=$(CHISEL_BUILD_DIR) SBT_EXTRA_DIR=$(SBT_EXTRA_DIR) $(MAKE) -C $(ROOT_DIR)/chisel verilog

# -----------------------------------------------------------------------------
# Test ------------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: test
test: $(BUILD_DIR)/registers.json ## run all tests
test: $(SCALA_BUILD_DIR)/RegisterDefs.scala
test: $(SCALA_BUILD_DIR)/CSRRegMap.scala
	SBT_EXTRA_DIR=$(SBT_EXTRA_DIR) $(MAKE) -C chisel testall

# -----------------------------------------------------------------------------
# Format ----------------------------------------------------------------------
# -----------------------------------------------------------------------------

format: ## format code
	find -name "*.sh" -not -path "$(THIRD_PARTY_DIR)/*" -not -path "$(BUILD_DIR)/*" | xargs -r shfmt -w --keep-padding
	find -name "*.sh" -not -path "$(THIRD_PARTY_DIR)/*" -not -path "$(BUILD_DIR)/*" | xargs -r shellcheck

# -----------------------------------------------------------------------------
# Docker ----------------------------------------------------------------------
# -----------------------------------------------------------------------------

$(DOCKER_BUILD_DIR):
	@mkdir -p $(DOCKER_BUILD_DIR)

$(DOCKER_BUILD_DIR)/docker.ok: hw.dockerfile $(REGGEN_DIR)/requirements.txt | $(DOCKER_BUILD_DIR) ## build development docker image
	cp $(ROOT_DIR)/hw.dockerfile $(DOCKER_BUILD_DIR)/Dockerfile
	cp $(REGGEN_DIR)/requirements.txt $(DOCKER_BUILD_DIR)
	cd $(DOCKER_BUILD_DIR) && docker build \
		--build-arg IMAGE_BASE="$(DOCKER_IMAGE_BASE)" \
		--build-arg REPO_ROOT="$(PWD)" \
		-t $(DOCKER_TAG) . && touch docker.ok

.PHONY: docker
docker: $(DOCKER_BUILD_DIR)/docker.ok ## build the developmend docker image

# -----------------------------------------------------------------------------
# Enter -----------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: enter
enter: $(DOCKER_BUILD_DIR)/docker.ok ## enter the development docker image
	docker run \
		--rm \
		-v $(PWD):$(PWD) \
		-v /etc/passwd:/etc/passwd \
		-v /etc/group:/etc/group \
		-v /tmp:$(HOME)/.cache \
		-v /tmp:$(HOME)/.sbt \
		-v /tmp:$(HOME)/.Xilinx \
		-u $(shell id -u):$(shell id -g) \
		-h docker-container \
		-w $(PWD) \
		-it $(DOCKER_TAG) || true

# -----------------------------------------------------------------------------
# Help ------------------------------------------------------------------------
# -----------------------------------------------------------------------------

HELP_COLUMN_SPAN = 20
HELP_FORMAT_STRING = "\033[36m%-$(HELP_COLUMN_SPAN)s\033[0m %s\n"
.PHONY: help
help: ## show this help
	@echo Here is the list of available targets:
	@echo ""
	@grep -E '^[a-zA-Z_\/-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf $(HELP_FORMAT_STRING), $$1, $$2}'
	@echo ""
	@echo "Additionally, you can use the following environment variables:"
	@echo ""
	@printf $(HELP_FORMAT_STRING) "BOARD" "The board to build the gateware for ('basalt' or 'zcu106')"
	@printf $(HELP_FORMAT_STRING) "BAR_SIZE" "bar size with unit (e.g. 16MB)"
	@printf $(HELP_FORMAT_STRING) "DOCKER_IMAGE_PREFIX" "custom registry prefix with '/' at the end"
	@printf $(HELP_FORMAT_STRING) "DOCKER_IMAGE_BASE" "custom docker image base"

.DEFAULT_GOAL := help
