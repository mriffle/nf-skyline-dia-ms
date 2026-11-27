#!/usr/bin/env python3
"""
Check how process scripts write the names of their input files.

A stub run cannot see this class of bug: stub blocks only `touch` files, so a script that
hands a tool a file name that does not exist still passes every stub config. The two rules
checked here are the ones in SPECIFICATION.md ("Input file names"):

1. A `path` input is never written inside quotes. Nextflow backslash-escapes a path variable
   so that it can be used bare (`my\\ file.fasta`); inside quotes the backslash survives and
   the tool is given a name that does not exist. Write it bare (`${fasta}`), or quote its
   name (`"${fasta.name}"`).

2. A name derived from an input (`${x.baseName}`, `${x.name}`, `${x.simpleName}`) is never
   written bare. It is not escaped, so a space splits it into two arguments. Quote it
   (`"${x.baseName}.ssl"`).

Only the `script:`, `shell:` and `stub:` blocks of processes are checked. Helper functions are
not: a path variable is escaped only where it is written directly in one of those blocks.

A line that is correct for a reason this script cannot see can be exempted by ending it with
the comment `# quoting-ok` (shell) or `// quoting-ok` (Groovy).

  Usage: test-resources/check-script-quoting.py [file.nf ...]     (default: modules/*.nf)
"""
import glob
import re
import sys

PROCESS_START = re.compile(r'^process\s+(\w+)\s*\{')
SECTION = re.compile(r'^\s*(input|output|when|script|shell|stub|exec)\s*:\s*$')
PATH_INPUT = re.compile(r'\bpath\s*\(?\s*([A-Za-z_]\w*)')
QUOTED = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'')
DERIVED = re.compile(r'^[A-Za-z_]\w*\.(?:baseName|name|simpleName)$')
PATH_TOKEN = re.compile(r'\x00P:(\w+)\x00')
DERIVED_TOKEN = re.compile(r'\x00D\x00')

# Processes that are not checked, and why.
EXEMPT_PROCESSES = {
    # QC reporting is being replaced; its scripts are left as they are until then.
    'EXPORT_GENE_REPORTS',
}

# Single lines that are not checked, as (process, text the line contains), and why.
EXEMPT_LINES = {
    # DIA-NN joins its arguments back into one string, so an unquoted name with a space still
    # works (real runs, DIA-NN 1.8.1 and 2.3.0). Quoting it would change the script of the
    # library prediction step, and Nextflow would then repeat that step and the whole search
    # for anyone who resumes a run started before the change.
    ('DIANN_BUILD_LIB', '--out-lib ${fasta_file.baseName}.speclib'),
}


def mask_expressions(line, path_inputs):
    """
    Replace every `${...}` in a script line with a token, so that what is left is shell text.

    `${x}` for a path input x becomes a token naming x, `${x.baseName}` (or .name,
    .simpleName) becomes a "derived name" token, and anything else becomes a neutral word.
    The last case covers Groovy expressions such as `${flag ? "mv ${files} dir/" : ''}`,
    whose quotes belong to Groovy and not to the shell.
    """
    out = []
    i = 0
    while i < len(line):
        if line.startswith('${', i) and (i == 0 or line[i - 1] != '\\'):
            depth = 0
            j = i + 1
            while j < len(line):
                if line[j] == '{':
                    depth += 1
                elif line[j] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            expression = line[i + 2:j].strip()
            if expression in path_inputs:
                out.append('\x00P:%s\x00' % expression)
            elif DERIVED.match(expression):
                out.append('\x00D\x00')
            else:
                out.append('GROOVY')
            i = j + 1
        else:
            out.append(line[i])
            i += 1
    return ''.join(out)


def check_file(path):
    problems = []
    process = None
    section = None
    path_inputs = set()

    with open(path, encoding='utf-8') as handle:
        lines = handle.read().split('\n')

    for number, line in enumerate(lines, start=1):
        start = PROCESS_START.match(line)
        if start:
            process, section, path_inputs = start.group(1), None, set()
            continue
        if process is None:
            continue
        if line.startswith('}'):
            process, section = None, None
            continue

        heading = SECTION.match(line)
        if heading:
            section = heading.group(1)
            continue

        if section == 'input':
            path_inputs.update(PATH_INPUT.findall(line))
            continue
        if section not in ('script', 'shell', 'stub'):
            continue

        stripped = line.strip()
        if not stripped or stripped.startswith('//') or 'quoting-ok' in line:
            continue

        if process in EXEMPT_PROCESSES:
            continue
        if any(process == name and text in line for name, text in EXEMPT_LINES):
            continue

        text = mask_expressions(line, path_inputs)

        # Rule 1: a path input written directly inside a quoted string.
        for quoted in QUOTED.findall(text):
            for name in PATH_TOKEN.findall(quoted):
                problems.append((number, process,
                                 'path input `%s` is written inside quotes; write it bare '
                                 'or use "${%s.name}"' % (name, name), stripped))

        # Rule 2: a derived name written outside any quoted string.
        outside = QUOTED.sub('""', text)
        for _ in DERIVED_TOKEN.findall(outside):
            problems.append((number, process,
                             'a name derived from an input (.baseName, .name) is not quoted',
                             stripped))

    return problems


def main(argv):
    files = argv[1:] or sorted(glob.glob('modules/*.nf'))
    if not files:
        print('No .nf files to check.', file=sys.stderr)
        return 2

    total = 0
    for path in files:
        for number, process, message, text in check_file(path):
            total += 1
            print('%s:%d: [%s] %s' % (path, number, process, message))
            print('    %s' % text)

    if total:
        print('\n%d problem(s). See "Input file names" in SPECIFICATION.md.' % total)
        return 1
    print('Script quoting is consistent in %d file(s).' % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
