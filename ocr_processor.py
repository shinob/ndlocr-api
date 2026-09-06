#!/usr/bin/env python3

import os
import sys
import time
import csv
import uuid
import urllib.request
from pathlib import Path
from types import SimpleNamespace
from datetime import datetime

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# NDLOCR-Lite (DEIM detector + PARSEQ recognizer) is vendored under extern/
# by `./setup.sh install` rather than bundled in this repo, since it ships
# ~150MB of ONNX model weights. See project.md for details.
EXTERN_SRC = Path(__file__).resolve().parent / "extern" / "ndlocr-lite" / "src"
if not EXTERN_SRC.is_dir():
    sys.exit(
        "NDLOCR-Liteが見つかりません。先に `./setup.sh install` を実行してください。\n"
        f"(期待したパス: {EXTERN_SRC})"
    )
sys.path.insert(0, str(EXTERN_SRC))

from ocr import get_detector, get_recognizer, _run_ocr_on_image_array  # noqa: E402


class OCRProcessor:
    def __init__(self):
        self.reader_args = SimpleNamespace(
            det_weights=str(EXTERN_SRC / "model" / "deim-s-1024x1024.onnx"),
            det_classes=str(EXTERN_SRC / "config" / "ndl.yaml"),
            det_score_threshold=0.2,
            det_conf_threshold=0.25,
            det_iou_threshold=0.2,
            rec_weights=str(EXTERN_SRC / "model" / "parseq-ndl-24x768-100-tiny-153epoch-tegaki3-r8data-202604.onnx"),
            rec_weights30=str(EXTERN_SRC / "model" / "parseq-ndl-24x256-30-tiny-189epoch-tegaki3-r8data-202604.onnx"),
            rec_weights50=str(EXTERN_SRC / "model" / "parseq-ndl-24x384-50-tiny-300epoch-tegaki3-r8data-202604.onnx"),
            rec_classes=str(EXTERN_SRC / "config" / "NDLmoji.yaml"),
            device="cpu",
            enable_tcy=False,
        )

        self.images_dir = Path('images')
        self.process_dir = Path('process')
        self.result_dir = Path('result')
        self.fonts_dir = Path('fonts')

        for directory in [self.images_dir, self.process_dir, self.result_dir, self.fonts_dir]:
            directory.mkdir(exist_ok=True)

        self.font = self.get_japanese_font()

        print("NDLOCR-Liteモデルを読み込み中（初回は少し時間がかかります）...")
        self.detector = get_detector(self.reader_args)
        self.recognizer100 = get_recognizer(self.reader_args)
        self.recognizer30 = get_recognizer(self.reader_args, weights_path=self.reader_args.rec_weights30)
        self.recognizer50 = get_recognizer(self.reader_args, weights_path=self.reader_args.rec_weights50)
        self.class_names = self.detector.classes  # {0: "text_block", 1: "line_main", ...}
        print("モデルの読み込みが完了しました")

    def get_japanese_font(self):
        """日本語フォントを取得（自動ダウンロード機能付き）"""
        font_path = self.fonts_dir / "NotoSansCJK-Regular.ttc"

        if not font_path.exists():
            print("日本語フォントをダウンロード中...")
            try:
                font_url = "https://github.com/googlefonts/noto-cjk/raw/main/Sans/OTC/NotoSansCJK-Regular.ttc"
                urllib.request.urlretrieve(font_url, font_path)
                print("日本語フォントのダウンロードが完了しました")
            except Exception as e:
                print(f"フォントのダウンロードに失敗しました: {e}")
                system_fonts = [
                    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
                    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                    "/System/Library/Fonts/Arial.ttf",  # macOS
                ]
                for system_font in system_fonts:
                    if Path(system_font).exists():
                        try:
                            return ImageFont.truetype(system_font, 16)
                        except Exception:
                            continue
                return ImageFont.load_default()

        try:
            return ImageFont.truetype(str(font_path), 16)
        except Exception as e:
            print(f"フォントの読み込みに失敗しました: {e}")
            return ImageFont.load_default()

    def get_image_files(self):
        """imagesディレクトリから画像ファイルを取得（NDL資料で使われるjp2も対応）"""
        image_extensions = ['*.jpg', '*.jpeg', '*.png', '*.bmp', '*.tif', '*.tiff', '*.jp2', '*.webp']
        image_files = []
        for ext in image_extensions:
            image_files.extend(self.images_dir.glob(ext))
            image_files.extend(self.images_dir.glob(ext.upper()))
        return image_files

    def generate_unique_filename(self, original_filename, suffix=""):
        """ユニークなファイル名を生成"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        unique_id = str(uuid.uuid4())[:8]
        original_stem = Path(original_filename).stem
        original_ext = Path(original_filename).suffix

        if suffix:
            return f"{timestamp}_{unique_id}_{suffix}_{original_stem}{original_ext}"
        return f"{timestamp}_{unique_id}_{original_stem}{original_ext}"

    def process_image(self, image_path):
        """単一画像のOCR処理（DEIMでレイアウト検出 → PARSEQで文字認識）"""
        try:
            pil_image = Image.open(str(image_path)).convert('RGB')
            img = np.array(pil_image, dtype=np.uint8)

            page_result = _run_ocr_on_image_array(
                detector=self.detector,
                recognizer30=self.recognizer30,
                recognizer50=self.recognizer50,
                recognizer100=self.recognizer100,
                inputname=image_path.name,
                img=img,
                outputpath=str(self.process_dir),
                save_viz=False,
            )
            json_lines = page_result["json_lines"]

            # 処理済み画像は常にPNGで保存（元の拡張子に関わらず統一）
            unique_processed_name = self.generate_unique_filename(image_path.stem + '.png', "processed")
            output_image_path = self.process_dir / unique_processed_name
            annotated_image = self.draw_results(pil_image.copy(), json_lines)
            annotated_image.save(output_image_path)

            csv_data = []
            for line in json_lines:
                box = line["boundingBox"]
                xs = [point[0] for point in box]
                ys = [point[1] for point in box]

                csv_data.append({
                    'original_filename': image_path.name,
                    'processed_filename': unique_processed_name,
                    'text': line["text"],
                    'confidence': float(line["confidence"]),
                    'x1': int(min(xs)),
                    'y1': int(min(ys)),
                    'x2': int(max(xs)),
                    'y2': int(max(ys)),
                    'is_vertical': line["isVertical"] == "true",
                    'class_name': self.class_names.get(line["class_index"], ""),
                    'timestamp': datetime.now().isoformat()
                })

            unique_csv_name = self.generate_unique_filename(f"{image_path.stem}.csv", "result")
            csv_filename = self.result_dir / unique_csv_name
            self.save_to_csv(csv_data, csv_filename)

            print(f"処理完了: {image_path.name}")
            print(f"  -> 処理済み画像: {unique_processed_name}")
            print(f"  -> CSV結果: {unique_csv_name}")
            print(f"  -> 検出テキスト数: {len(json_lines)}個")
            return True

        except Exception as e:
            print(f"画像処理中にエラーが発生しました: {image_path} - {str(e)}")
            return False

    def draw_results(self, pil_image, json_lines):
        """OCR結果を画像に描画（矩形は緑、認識テキストは黒、信頼度は赤）"""
        draw = ImageDraw.Draw(pil_image)

        for line in json_lines:
            box = line["boundingBox"]
            xs = [point[0] for point in box]
            ys = [point[1] for point in box]
            x1, y1, x2, y2 = min(xs), min(ys), max(xs), max(ys)

            draw.rectangle([x1, y1, x2, y2], outline=(0, 255, 0), width=2)

            text = line["text"]
            if not text:
                continue

            text_x, text_y = x1, y1 - 25
            if text_y < 0:
                text_y = y2 + 5

            try:
                bbox_text = draw.textbbox((0, 0), text, font=self.font)
                text_width = bbox_text[2] - bbox_text[0]
                text_height = bbox_text[3] - bbox_text[1]
            except Exception:
                text_width = len(text) * 10
                text_height = 16

            draw.rectangle(
                [text_x, text_y - text_height - 2, text_x + text_width + 4, text_y + 2],
                fill=(0, 255, 0)
            )
            draw.text((text_x + 2, text_y - text_height), text, font=self.font, fill=(0, 0, 0))

            confidence_text = f"{float(line['confidence']):.2f}"
            draw.text((text_x + 2, text_y + 5), confidence_text, font=self.font, fill=(255, 0, 0))

        return pil_image

    def save_to_csv(self, data, filename):
        """データをCSVファイルに保存（テキスト未検出時もヘッダーのみ作成）"""
        with open(filename, 'w', newline='', encoding='utf-8') as csvfile:
            fieldnames = [
                'original_filename', 'processed_filename', 'text', 'confidence',
                'x1', 'y1', 'x2', 'y2', 'is_vertical', 'class_name', 'timestamp'
            ]
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            writer.writeheader()
            for row in data:
                writer.writerow(row)

    def run_continuous(self):
        """継続的な画像監視とOCR処理"""
        print("OCR処理を開始します。Ctrl+Cで終了します。")

        try:
            while True:
                image_files = self.get_image_files()

                if image_files:
                    print(f"{len(image_files)}個の画像ファイルが見つかりました。")

                    for image_path in image_files:
                        success = self.process_image(image_path)

                        if success:
                            try:
                                os.remove(image_path)
                                print(f"画像ファイルを削除しました: {image_path.name}")
                            except Exception as e:
                                print(f"ファイル削除中にエラーが発生しました: {image_path} - {str(e)}")

                time.sleep(1)

        except KeyboardInterrupt:
            print("\nOCR処理を終了します。")


def main():
    processor = OCRProcessor()
    processor.run_continuous()


if __name__ == "__main__":
    main()
