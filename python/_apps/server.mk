python_root := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST))))..)/

# Current PyInstaller output sizes with 10% rails.
# Min size is important, in case Python suddenly drops a library or something.
server_onefile_minsize := 70M
server_onefile_maxsize := 90M
server_onedir_minsize  := 190
server_onedir_maxsize  := 230



server-onefile: dist/server-onefile-tmp
	# Try running it, just to confirm it's executable
	"./$^" --help > /dev/null
	# Check that the size of the target file hasn't changed by too much.
	# NB If these are unreasonably large, uninstall a bunch of packages:
	#
	#     pip uninstall torch pyarrow transformers pandas sympy
	#
	test        -n "$$(find "$^" -a -size +$(server_onefile_minsize))" \
	    && test -n "$$(find "$^" -a -size -$(server_onefile_maxsize))" \
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
	# NB Having a Finder window open + compute directory sizes will create .DS_Store files,
	#    which makes parts of the build fail because we couldn't remove a directory.
	rm -rf dist/server-internal
	test        "$$(du -sm dist/server-onedir-tmp/ | awk '{print $$1}')" -gt "$(server_onedir_minsize)" \
	    && test "$$(du -sm dist/server-onedir-tmp/ | awk '{print $$1}')" -lt "$(server_onedir_maxsize)" \
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
