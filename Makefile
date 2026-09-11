# Seed — build e empacotamento (sem Xcode)
# Uso: make app   → gera dist/Seed.app assinado (ad-hoc) e pronto para abrir
#      make run   → build + abre o app
#      make cli   → só o seed-spike (CLI de debug)

# .toolchain-fix só existe na máquina com o CLT 16.4 corrompido (ver README);
# em máquinas saudáveis o build roda sem a variável
SPM_ENV := $(shell [ -d $(CURDIR)/.toolchain-fix/pm ] && echo SWIFTPM_CUSTOM_LIBS_DIR=$(CURDIR)/.toolchain-fix/pm)
APP := dist/Seed.app
# identidade estável "Seed Dev" (scripts/make-cert.sh) preserva as permissões
# do TCC entre builds; sem ela, cai no ad-hoc (re-pede permissões)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Seed Dev" && echo Seed Dev || echo -)

.PHONY: app run cli mcp test test-mcp clean

app:
	$(SPM_ENV) swift build -c release --product SeedApp
	$(SPM_ENV) swift build -c release --product seed-mcp
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/SeedApp $(APP)/Contents/MacOS/Seed
	cp .build/release/seed-mcp $(APP)/Contents/MacOS/seed-mcp
	codesign --force --sign "$(SIGN_ID)" $(APP)/Contents/MacOS/seed-mcp
	cp packaging/Info.plist $(APP)/Contents/Info.plist
	cp packaging/Seed.icns $(APP)/Contents/Resources/Seed.icns
	codesign --force --sign "$(SIGN_ID)" $(APP)
	# re-registra no LaunchServices: o rm -rf + recriar deixa o cache de ícone
	# podre (ícone genérico em notificações/bolhas depois de alguns builds)
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $(APP)
	@echo "✅ $(APP) pronto (assinado: $(SIGN_ID))"

run: app
	open $(APP)

cli:
	$(SPM_ENV) swift build -c release --product seed-spike

mcp:
	$(SPM_ENV) swift build -c release --product seed-mcp

test-mcp: mcp
	python3 scripts/test-mcp.py

test:
	$(SPM_ENV) swift test

clean:
	rm -rf .build dist
