import argparse
import json
import pathlib
import sys

import yaml


class _IndentedListDumper(yaml.SafeDumper):
    def increase_indent(self, flow: bool = False, indentless: bool = False) -> None:
        super().increase_indent(flow, False)


def _format_yaml_error(*, error: yaml.YAMLError) -> str:
    return "; ".join(line.strip() for line in str(error).splitlines() if line.strip())


def _write_yaml_file_as_json(*, source: pathlib.Path) -> None:
    with source.open(encoding="utf-8") as stream:
        try:
            documents = list(yaml.safe_load_all(stream))
        except yaml.YAMLError as error:
            print(_format_yaml_error(error=error), file=sys.stderr)
            raise SystemExit(1) from None
    for document in documents:
        json.dump(document, sys.stdout, default=str)
        sys.stdout.write("\n")


def _write_json_input_as_yaml() -> None:
    yaml.dump(json.load(sys.stdin), sys.stdout, Dumper=_IndentedListDumper, sort_keys=False, allow_unicode=True)


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Convert the settings file between YAML and JSON.")
    conversions = parser.add_subparsers(dest="conversion", required=True)
    to_json = conversions.add_parser("to-json", help="print the YAML file SOURCE as JSON")
    to_json.add_argument("source", type=pathlib.Path)
    conversions.add_parser("to-yaml", help="print JSON read from standard input as YAML")
    return parser.parse_args()


if __name__ == "__main__":
    arguments = _parse_arguments()
    match arguments.conversion:
        case "to-json":
            _write_yaml_file_as_json(source=arguments.source)
        case "to-yaml":
            _write_json_input_as_yaml()
        case _:
            raise ValueError("unknown conversion", arguments.conversion)
