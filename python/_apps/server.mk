python_root := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST))))..)/
python_amd64 := /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11-intel64

socks_proxy_wheel := $(wildcard $(HOME)/Documents/PySocks-1.7.1-py3-none-any.whl)



server-onefile: dist/server-onefile-tmp
	# Try running it, just to confirm it's executable
	"./$^" --help > /dev/null
	# Check that the size of the target file hasn't changed by too much.
	# NB If these are unreasonably large, uninstall a bunch of packages:
	#
	#     pip uninstall torch pyarrow transformers pandas sympy
	#
	test -n "$$(find "$^" -a -size +75M)" \
	    && test -n "$$(find "$^" -a -size -91M)" \
	    && mv "$^" "dist/brokegen-server"

# Make this .PHONY because we rely on pyinstaller to rebuild constantly.
.PHONY: dist/server-onefile-tmp
dist/server-onefile-tmp: $(pyinstaller_inference_venv)
	source "$(pyinstaller_inference_venv)"/bin/activate \
		&& arch -x86_64 pyinstaller \
			--target-architecture x86_64 \
			--log-level WARN \
			--noupx --console \
			--noconfirm \
			--paths $(python_root) \
			--hidden-import llama_cpp \
			--collect-all llama_cpp \
			--specpath build \
			--onefile \
			--name "server-onefile-tmp" \
			$(python_root)_apps/server.py



build: server-onedir
dist: server-onedir
server-onedir: dist/server-onedir-tmp
	"./dist/server-onedir-tmp/server-onedir-tmp" --help > /dev/null
	rm -rf dist/server-internal
	test "$$(du -sm dist/server-onedir-tmp/ | awk '{print $$1}')" -gt "261" \
	    && test "$$(du -sm dist/server-onedir-tmp/ | awk '{print $$1}')" -lt "319" \
	    && mv dist/server-onedir-tmp/server-internal dist/server-internal \
	    && mv dist/server-onedir-tmp/server-onedir-tmp dist/server-onedir

.PHONY: dist/server-onedir-tmp
dist/server-onedir-tmp: $(pyinstaller_inference_venv)
	source "$(pyinstaller_inference_venv)"/bin/activate \
		&& arch -x86_64 pyinstaller \
			--target-architecture x86_64 \
			--log-level WARN \
			--noupx --console \
			--noconfirm \
			--debug noarchive \
			--paths $(python_root) \
			--hidden-import llama_cpp \
			--collect-all llama_cpp \
			--specpath build \
			--onedir --contents-directory "server-internal" \
			--name "server-onedir-tmp" \
			$(python_root)_apps/server.py

.PHONY: run-server
run-server: data/
	PYTHONPATH=$(python_root) \
		python $(python_root)_apps/server.py --data-dir data/ --log-level debug
