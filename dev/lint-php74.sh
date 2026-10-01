#!/bin/sh
# PHP 7.4 syntax lint of the whole plugin.
cd "$(dirname "$0")/.." && docker run --rm -v "$PWD/fastflowpe-checkout:/p" php:7.4-cli sh -c 'php -v | head -1; fail=0; for f in $(find /p -name "*.php"); do php -l $f >/dev/null 2>&1 || { php -l $f; fail=1; }; done; [ $fail = 0 ] && echo "PHP 7.4 lint OK"; exit $fail'
