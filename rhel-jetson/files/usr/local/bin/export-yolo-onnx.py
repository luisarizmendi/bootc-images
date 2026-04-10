import argparse
from ultralytics import YOLO

def main():
    parser = argparse.ArgumentParser(
        description="Export a YOLO model to ONNX format."
    )

    parser.add_argument(
        "model",
        type=str,
        help="Path to the YOLO model file (e.g., yolo11n.pt)"
    )

    parser.add_argument(
        "--format",
        type=str,
        default="onnx",
        help="Export format (default: onnx)"
    )

    args = parser.parse_args()

    # Load model
    model = YOLO(args.model)

    # Export
    model.export(format=args.format)

if __name__ == "__main__":
    main()