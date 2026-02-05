#!/usr/bin/env bash
set -euo pipefail

THEME_ROOT="${1:?theme_root required}"
THEME_SLUG="${2:?theme_slug required}"
WORKDIR="${3:?workdir required}"

LOG_DIR="${WORKDIR}/logs"
mkdir -p "${LOG_DIR}"

REPORT_MD="${WORKDIR}/report.md"
RESULTS_JSON="${WORKDIR}/results.json"

PHP_LINT_LOG="${LOG_DIR}/php-lint.log"
PHPCS_BEFORE_JSON="${LOG_DIR}/phpcs-before.json"
PHPCS_AFTER_JSON="${LOG_DIR}/phpcs-after.json"
ESLINT_BEFORE_JSON="${LOG_DIR}/eslint-before.json"
ESLINT_AFTER_JSON="${LOG_DIR}/eslint-after.json"
STYLELINT_BEFORE_JSON="${LOG_DIR}/stylelint-before.json"
STYLELINT_AFTER_JSON="${LOG_DIR}/stylelint-after.json"
FIX_LOG="${LOG_DIR}/fix.log"

# Choose actual theme directory to operate on
if [[ -d "${THEME_ROOT}/${THEME_SLUG}" ]]; then
  TARGET="${THEME_ROOT}/${THEME_SLUG}"
else
  TARGET="${THEME_ROOT}"
fi

echo "# Theme CI Report" > "${REPORT_MD}"
echo "" >> "${REPORT_MD}"
echo "## Target" >> "${REPORT_MD}"
echo "- Theme root: \`${THEME_ROOT}\`" >> "${REPORT_MD}"
echo "- Target: \`${TARGET}\`" >> "${REPORT_MD}"
echo "- Slug: \`${THEME_SLUG}\`" >> "${REPORT_MD}"
echo "" >> "${REPORT_MD}"

echo "== PHP lint ==" | tee "${PHP_LINT_LOG}"
PHP_FILES=$(find "${TARGET}" -type f -name "*.php" ! -path "*/vendor/*" ! -path "*/node_modules/*" || true)
PHP_LINT_OK=1
if [[ -n "${PHP_FILES}" ]]; then
  while IFS= read -r f; do
    if ! php -l "$f" >> "${PHP_LINT_LOG}" 2>&1; then
      PHP_LINT_OK=0
    fi
  done <<< "${PHP_FILES}"
fi

echo "" >> "${REPORT_MD}"
echo "## PHP syntax (php -l)" >> "${REPORT_MD}"
if [[ "${PHP_LINT_OK}" == "1" ]]; then
  echo "- ✅ PASS" >> "${REPORT_MD}"
else
  echo "- ❌ FAIL (see logs/php-lint.log)" >> "${REPORT_MD}"
fi

echo "" >> "${REPORT_MD}"
echo "## PHPCS / PHPCBF (WPCS)" >> "${REPORT_MD}"

# PHPCS before
./ci/vendor/bin/phpcs -q --report=json --standard=./ci/phpcs.xml.dist "${TARGET}" > "${PHPCS_BEFORE_JSON}" || true

# PHPCBF fixes
echo "== PHPCBF (autofix) ==" | tee -a "${FIX_LOG}"
./ci/vendor/bin/phpcbf -q --standard=./ci/phpcs.xml.dist "${TARGET}" >> "${FIX_LOG}" 2>&1 || true

# PHPCS after
./ci/vendor/bin/phpcs -q --report=json --standard=./ci/phpcs.xml.dist "${TARGET}" > "${PHPCS_AFTER_JSON}" || true

echo "- Ran PHPCS before/after and PHPCBF." >> "${REPORT_MD}"
echo "- Logs: \`logs/phpcs-before.json\`, \`logs/phpcs-after.json\`, \`logs/fix.log\`" >> "${REPORT_MD}"

# ESLint (optional)
echo "" >> "${REPORT_MD}"
echo "## ESLint (optional)" >> "${REPORT_MD}"
JS_EXISTS=$(find "${TARGET}" -type f \( -name "*.js" -o -name "*.mjs" -o -name "*.cjs" \) ! -path "*/node_modules/*" | head -n 1 || true)

if [[ -n "${JS_EXISTS}" ]]; then
  # before
  npx -y eslint "${TARGET}" -c ./ci/.eslintrc.cjs --format json > "${ESLINT_BEFORE_JSON}" 2>/dev/null || true
  # fix
  npx -y eslint "${TARGET}" -c ./ci/.eslintrc.cjs --fix >> "${FIX_LOG}" 2>&1 || true
  # after
  npx -y eslint "${TARGET}" -c ./ci/.eslintrc.cjs --format json > "${ESLINT_AFTER_JSON}" 2>/dev/null || true
  echo "- Ran ESLint before/after with \`--fix\`." >> "${REPORT_MD}"
  echo "- Logs: \`logs/eslint-before.json\`, \`logs/eslint-after.json\`" >> "${REPORT_MD}"
else
  echo "- Skipped (no JS files detected)." >> "${REPORT_MD}"
fi

# Stylelint (optional)
echo "" >> "${REPORT_MD}"
echo "## Stylelint (optional)" >> "${REPORT_MD}"
CSS_EXISTS=$(find "${TARGET}" -type f -name "*.css" ! -path "*/node_modules/*" | head -n 1 || true)

if [[ -n "${CSS_EXISTS}" ]]; then
  # before
  npx -y stylelint "${TARGET}/**/*.css" --config ./ci/.stylelintrc.json --formatter json > "${STYLELINT_BEFORE_JSON}" 2>/dev/null || true
  # fix
  npx -y stylelint "${TARGET}/**/*.css" --config ./ci/.stylelintrc.json --fix >> "${FIX_LOG}" 2>&1 || true
  # after
  npx -y stylelint "${TARGET}/**/*.css" --config ./ci/.stylelintrc.json --formatter json > "${STYLELINT_AFTER_JSON}" 2>/dev/null || true
  echo "- Ran Stylelint before/after with \`--fix\`." >> "${REPORT_MD}"
  echo "- Logs: \`logs/stylelint-before.json\`, \`logs/stylelint-after.json\`" >> "${REPORT_MD}"
else
  echo "- Skipped (no CSS files detected)." >> "${REPORT_MD}"
fi

# Normalize findings into results.json (simple, robust approach)
python3 - <<'PY'
import json, os, glob

workdir = os.environ["WORKDIR"]
log_dir = os.path.join(workdir, "logs")

def phpcs_findings(path, tool="phpcs"):
    out=[]
    if not os.path.exists(path): return out
    try:
        data=json.load(open(path))
    except Exception:
        return out
    for fpath, fdata in data.get("files", {}).items():
        for m in fdata.get("messages", []):
            out.append({
                "tool": tool,
                "severity": "error" if m.get("type") == "ERROR" else "warning",
                "file": fpath,
                "line": m.get("line"),
                "message": m.get("message", ""),
            })
    return out

def eslint_findings(path):
    out=[]
    if not os.path.exists(path): return out
    try:
        data=json.load(open(path))
    except Exception:
        return out
    for entry in data:
        for m in entry.get("messages", []):
            out.append({
                "tool": "eslint",
                "severity": "error" if m.get("severity") == 2 else "warning",
                "file": entry.get("filePath"),
                "line": m.get("line"),
                "message": m.get("message", ""),
            })
    return out

def stylelint_findings(path):
    out=[]
    if not os.path.exists(path): return out
    try:
        data=json.load(open(path))
    except Exception:
        return out
    for entry in data:
        for w in entry.get("warnings", []):
            out.append({
                "tool": "stylelint",
                "severity": w.get("severity","warning"),
                "file": entry.get("source"),
                "line": w.get("line"),
                "message": w.get("text",""),
            })
    return out

before = []
after = []

before += phpcs_findings(os.path.join(log_dir,"phpcs-before.json"))
after  += phpcs_findings(os.path.join(log_dir,"phpcs-after.json"))

before += eslint_findings(os.path.join(log_dir,"eslint-before.json"))
after  += eslint_findings(os.path.join(log_dir,"eslint-after.json"))

before += stylelint_findings(os.path.join(log_dir,"stylelint-before.json"))
after  += stylelint_findings(os.path.join(log_dir,"stylelint-after.json"))

results = {
  "ok": True,
  "summary": {
    "errors_before": sum(1 for f in before if f["severity"]=="error"),
    "errors_after":  sum(1 for f in after if f["severity"]=="error"),
    "warnings_before": sum(1 for f in before if f["severity"]!="error"),
    "warnings_after":  sum(1 for f in after if f["severity"]!="error"),
  },
  "findings_before": before,
  "findings_after": after,
}

# ok = no "after" errors AND PHP lint log didn't record errors (best-effort)
results["ok"] = results["summary"]["errors_after"] == 0

with open(os.path.join(workdir,"results.json"),"w") as f:
    json.dump(results,f,indent=2)
PY
export WORKDIR="${WORKDIR}"

echo "" >> "${REPORT_MD}"
echo "## Summary" >> "${REPORT_MD}"
echo "- results.json written to \`${RESULTS_JSON}\`" >> "${REPORT_MD}"
echo "- Patched files are in-place under \`${TARGET}\` (workflow later packages patched.zip)" >> "${REPORT_MD}"
