FPC      ?= fpc
BUILD    := build
FPCFLAGS := -O2 -gl -vewn -Sh -Fusrc -FU$(BUILD)/units -FE$(BUILD)

SOURCES := $(wildcard src/*.pas)

.PHONY: all demo test samples check-samples run clean

all: demo $(BUILD)/testrunner

$(BUILD)/units:
	mkdir -p $@

$(BUILD)/bedsidelink: demo/bedsidelink.pas $(SOURCES) | $(BUILD)/units
	$(FPC) $(FPCFLAGS) $<

$(BUILD)/testrunner: tests/testrunner.pas $(wildcard tests/*.pas) $(SOURCES) | $(BUILD)/units
	$(FPC) $(FPCFLAGS) -Futests $<

$(BUILD)/gensamples: tools/gensamples.pas $(SOURCES) | $(BUILD)/units
	$(FPC) $(FPCFLAGS) $<

demo: $(BUILD)/bedsidelink

run: demo
	$(BUILD)/bedsidelink --data data

test: $(BUILD)/testrunner demo
	$(BUILD)/testrunner --all --format=plain --data=data
	tests/demo_smoke.sh $(BUILD)/bedsidelink data

# Regenerate the recorded streams in data/.
samples: $(BUILD)/gensamples
	$(BUILD)/gensamples data

# Fails if the committed streams differ from what the generator produces.
check-samples: $(BUILD)/gensamples
	mkdir -p $(BUILD)/samples
	$(BUILD)/gensamples $(BUILD)/samples > /dev/null
	cmp $(BUILD)/samples/monitor_bed01.bin data/monitor_bed01.bin
	cmp $(BUILD)/samples/ventilator_bed01.bin data/ventilator_bed01.bin
	cmp $(BUILD)/samples/pump_bed02.bin data/pump_bed02.bin

clean:
	rm -rf $(BUILD)
