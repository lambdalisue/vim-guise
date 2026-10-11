.DEFAULT_GOAL := help

help:
	@cat $(MAKEFILE_LIST) | \
	    perl -ne 'print if /^\w+.*##/;' | \
	    perl -pe 's/(.*):.*##\s*/sprintf("%-20s",$$1)/eg;'

test: test-vim test-nvim	## Test on Vim and Neovim

test-vim: FORCE	## Test on Vim
	@vim -Nu NONE -i NONE -n -es -S test/guise.vim

test-nvim: FORCE	## Test on Neovim
	@nvim --headless --clean -S test/guise.vim

FORCE:
