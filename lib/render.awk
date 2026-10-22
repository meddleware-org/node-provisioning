# Deterministic template renderer. Values and include paths arrive only through the environment
# (ENVIRON), never through argv. A template contains:
#   @@NAME@@                 replaced by the value of NAME
#   <indent>@@INCLUDE:NAME@@ replaced by the lines of the file NAME, each prefixed with <indent>
#   # UBUNTU_PRO_START / # UBUNTU_PRO_END   block kept (markers removed) when a token is set, else removed
# Any unreplaced marker left after substitution is an error.
function replace_all(s, from, to,    out, i) {
  out = ""
  while ((i = index(s, from)) > 0) {
    out = out substr(s, 1, i - 1) to
    s = substr(s, i + length(from))
  }
  return out s
}
function err(msg) {
  print "render: " msg > "/dev/stderr"
  bad = 1
}
BEGIN {
  n = split(ENVIRON["NP_VARS"], vn, " ")
  for (i = 1; i <= n; i++) val[vn[i]] = ENVIRON["NP_V_" vn[i]]
  n = split(ENVIRON["NP_INCS"], inn, " ")
  for (i = 1; i <= n; i++) incpath[inn[i]] = ENVIRON["NP_I_" inn[i]]
  pro = (ENVIRON["NP_PRO"] == "1")
  skip = 0
  bad = 0
}
{
  line = $0
  if (index(line, "# UBUNTU_PRO_START")) {
    if (pro) next
    skip = 1
  }
  if (skip) {
    if (index(line, "# UBUNTU_PRO_END")) skip = 0
    next
  }
  if (pro && index(line, "# UBUNTU_PRO_END")) next

  if (line ~ /^ *@@INCLUDE:[A-Z0-9_]+@@ *$/) {
    indent = line; sub(/[^ ].*$/, "", indent)
    name = line; sub(/^ *@@INCLUDE:/, "", name); sub(/@@ *$/, "", name)
    if (!(name in incpath)) { err("no include named " name " (line " NR ")"); next }
    path = incpath[name]; nl = 0
    while ((getline frag < path) > 0) {
      nl++
      if (frag == "") print ""; else print indent frag
    }
    close(path)
    if (nl == 0) err("include " name " is empty or unreadable")
    next
  }

  for (k in val) line = replace_all(line, "@@" k "@@", val[k])
  if (line ~ /@@[A-Z][A-Z0-9_]*@@/) err("unreplaced marker on template line " NR)
  print line
}
END { exit bad }
