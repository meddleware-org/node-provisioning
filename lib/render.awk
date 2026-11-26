# Deterministic template renderer. Values and include paths arrive only through the environment
# (ENVIRON), never through argv. A template contains:
#   @@NAME@@                 replaced by the value of NAME
#   <indent>@@INCLUDE:NAME@@ replaced by the lines of the file NAME, each prefixed with <indent>
#   # UBUNTU_PRO_START / # UBUNTU_PRO_END   block kept (markers removed) when a token is set, else removed
# Any unreplaced marker left after substitution is an error.
# replace_all(s, from, to): every occurrence of `from` in `s` replaced by `to`, with no regular-expression meaning (index/substr, so a value is never interpreted).
function replace_all(s, from, to,    out, i) {
  out = ""
  while ((i = index(s, from)) > 0) {
    out = out substr(s, 1, i - 1) to
    s = substr(s, i + length(from))
  }
  return out s
}
# err(msg): report a render problem on stderr and remember it, so the whole template is checked and the exit status is non-zero at the end.
function err(msg) {
  print "render: " msg > "/dev/stderr"
  bad = 1
}
# Load the values and include paths from the environment into arrays, and the Pro switch.
BEGIN {
  n = split(ENVIRON["NP_VARS"], vn, " ")
  for (i = 1; i <= n; i++) val[vn[i]] = ENVIRON["NP_V_" vn[i]]
  n = split(ENVIRON["NP_INCS"], inn, " ")
  for (i = 1; i <= n; i++) incpath[inn[i]] = ENVIRON["NP_I_" inn[i]]
  # Whether the Ubuntu Pro block is kept (a token was given).
  pro = (ENVIRON["NP_PRO"] == "1")
  # skip: inside a removed Pro block. bad: a problem was reported.
  skip = 0
  bad = 0
}
{
  # Each template line: first the Pro block markers.
  line = $0
  # With a token the markers themselves are dropped and the block kept; without one the block, markers included, is removed.
  if (index(line, "# UBUNTU_PRO_START")) {
    if (pro) next
    skip = 1
  }
  # Inside a removed block: drop lines until its end marker.
  if (skip) {
    if (index(line, "# UBUNTU_PRO_END")) skip = 0
    next
  }
  # With a token, the end marker line is dropped too.
  if (pro && index(line, "# UBUNTU_PRO_END")) next

  # An include line: the whole line is replaced by the named file, each line indented like the marker so the YAML stays valid.
  if (line ~ /^ *@@INCLUDE:[A-Z0-9_]+@@ *$/) {
    indent = line; sub(/[^ ].*$/, "", indent)
    name = line; sub(/^ *@@INCLUDE:/, "", name); sub(/@@ *$/, "", name)
    # An include nobody supplied is an error.
    if (!(name in incpath)) { err("no include named " name " (line " NR ")"); next }
    path = incpath[name]; nl = 0
    while ((getline frag < path) > 0) {
      nl++
      # Blank lines stay blank (no trailing spaces).
      if (frag == "") print ""; else print indent frag
    }
    close(path)
    # An empty or unreadable file is an error, not an empty include.
    if (nl == 0) err("include " name " is empty or unreadable")
    next
  }

  # Ordinary lines: substitute every @@NAME@@.
  for (k in val) line = replace_all(line, "@@" k "@@", val[k])
  # Anything still of the form @@NAME@@ is a missing value; a template can never ship with a marker left in.
  if (line ~ /@@[A-Z][A-Z0-9_]*@@/) err("unreplaced marker on template line " NR)
  print line
}
# Exit non-zero when any problem was reported.
END { exit bad }
