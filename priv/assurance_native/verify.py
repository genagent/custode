"""Pinned deterministic contract, with no provider-authored pass classification."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
from baseline import baseline_add

pairs = [(0, 0), (1, 2), (-2, 1), (-4, -3), (123, 99)]
result = {"artifact_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
          "check_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          "checks": [], "failure": None}
try:
    # The native producer owns this small function, not fixture/check files.
    # Interpret only the bounded wrapper grammar, never arbitrary submitted code.
    tree = ast.parse(Path("submission.py").read_text())
    defs = [node for node in tree.body if isinstance(node, ast.FunctionDef)]
    imports = [node for node in tree.body if isinstance(node, ast.ImportFrom)]
    assert len(defs) == 1 and len(imports) == 1 and len(tree.body) == 2, "one import and function required"
    imp = imports[0]
    assert imp.module == "baseline" and imp.level == 0 and len(imp.names) == 1
    assert imp.names[0].name == "baseline_add" and imp.names[0].asname is None
    fn = defs[0]
    assert fn.name == "sum_pair" and not fn.decorator_list, "sum_pair required"
    assert [arg.arg for arg in fn.args.args] == ["a", "b"], "two arguments required"
    assert not fn.args.defaults and not fn.args.vararg and not fn.args.kwarg
    assert not fn.args.posonlyargs and not fn.args.kwonlyargs and not fn.args.kw_defaults
    assert not fn.returns and not getattr(fn, "type_params", [])
    assert all(arg.annotation is None for arg in fn.args.args)
    assert len(fn.body) == 1 and isinstance(fn.body[0], ast.Return), "one return required"
    call = fn.body[0].value
    assert isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
    assert call.func.id == "baseline_add" and not call.keywords
    assert len(call.args) == 2 and all(isinstance(arg, ast.Name) for arg in call.args)
    assert [arg.id for arg in call.args] == ["a", "b"], "delegate exact arguments"
    namespace = {"__builtins__": {}, "baseline_add": baseline_add}
    exec(compile(ast.Module(body=[fn], type_ignores=[]), "submission.py", "exec"), namespace)
    for a, b in pairs:
        observed = baseline_add(a, b)
        result["checks"].append({"check": "baseline_add", "input": [a, b],
                                 "expected": a + b, "observed": observed, "passed": observed == a + b})
        observed = namespace["sum_pair"](a, b)
        result["checks"].append({"check": "sum_pair", "input": [a, b],
                                 "expected": a + b, "observed": observed, "passed": observed == a + b})
except (AssertionError, SyntaxError, FileNotFoundError) as error:
    result["failure"] = str(error)
passed = result["failure"] is None and len(result["checks"]) == 10 and all(c["passed"] for c in result["checks"])
result["passed"] = passed
print(json.dumps(result, sort_keys=True))
raise SystemExit(0 if passed else 1)
