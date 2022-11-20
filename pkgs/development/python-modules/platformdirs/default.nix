{ lib
, appdirs
, buildPythonPackage
, fetchFromGitHub
, pytest-mock
, pytestCheckHook
, pythonOlder
, hatchling
, hatch-vcs
}:

buildPythonPackage rec {
  pname = "platformdirs";
  version = "2.5.3";
  format = "pyproject";

  disabled = pythonOlder "3.7";

  src = fetchFromGitHub {
    owner = pname;
    repo = pname;
    rev = "refs/tags/${version}";
    hash = "sha256-OAvhbgmwGhElszUPksXkOgB5Dp/Wcf4s8807CcT7eyM=";
  };

  SETUPTOOLS_SCM_PRETEND_VERSION = version;

  nativeBuildInputs = [
    hatchling
    hatch-vcs
  ];

  checkInputs = [
    appdirs
    pytest-mock
    pytestCheckHook
  ];

  pythonImportsCheck = [
    "platformdirs"
  ];

  meta = with lib; {
    description = "Module for determining appropriate platform-specific directories";
    homepage = "https://platformdirs.readthedocs.io/";
    changelog = "https://github.com/platformdirs/platformdirs/releases/tag/${version}";
    license = licenses.mit;
    maintainers = with maintainers; [ fab ];
  };
}
