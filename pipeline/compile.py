
from pathlib import Path

from kfp import compiler

from pipeline.iris_pipeline import iris_ml_pipeline


def main() -> None:
    output = Path(__file__).resolve().parent / "iris_pipeline.yaml"

    compiler.Compiler().compile(
        pipeline_func=iris_ml_pipeline,
        package_path=str(output),
    )

    print(f"Pipeline compiled successfully: {output}")


if __name__ == "__main__":
    main()
