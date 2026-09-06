#!/usr/bin/env python3

import os
import uuid
import csv
import json
from pathlib import Path
from typing import Optional, List, Dict, Any
from datetime import datetime
import shutil

from fastapi import FastAPI, File, UploadFile, HTTPException, Form
from fastapi.responses import FileResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import pdf2image
from PIL import Image
import io

app = FastAPI(title="NDLOCR-Lite API", description="OCR processing API with file upload and result retrieval")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class OCRAPIManager:
    def __init__(self):
        self.images_dir = Path('images')
        self.process_dir = Path('process')
        self.result_dir = Path('result')
        self.uploads_dir = Path('uploads')

        for directory in [self.images_dir, self.process_dir, self.result_dir, self.uploads_dir]:
            directory.mkdir(exist_ok=True)

    def generate_unique_filename(self, original_filename: str) -> str:
        """一意のファイル名を生成"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        unique_id = str(uuid.uuid4())[:8]
        file_extension = Path(original_filename).suffix.lower()

        return f"{timestamp}_{unique_id}_{Path(original_filename).stem}{file_extension}"

    def convert_pdf_to_images(self, pdf_path: Path) -> List[Path]:
        """PDFを画像に変換"""
        try:
            images = pdf2image.convert_from_path(pdf_path, dpi=300)
            image_paths = []

            for i, image in enumerate(images):
                image_filename = f"{pdf_path.stem}_page_{i+1:03d}.png"
                image_path = self.images_dir / image_filename
                image.save(image_path, 'PNG')
                image_paths.append(image_path)

            return image_paths
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"PDF変換エラー: {str(e)}")

    def convert_tif_to_images(self, tif_path: Path) -> List[Path]:
        """TIF（マルチページ対応）をページごとのPNG画像に変換"""
        try:
            image_paths = []
            with Image.open(tif_path) as img:
                n_frames = getattr(img, 'n_frames', 1)
                for i in range(n_frames):
                    img.seek(i)
                    image_filename = f"{tif_path.stem}_page_{i+1:03d}.png"
                    image_path = self.images_dir / image_filename
                    img.convert('RGB').save(image_path, 'PNG')
                    image_paths.append(image_path)
            return image_paths
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"TIF変換エラー: {str(e)}")

    def save_uploaded_file(self, file: UploadFile) -> Path:
        """アップロードされたファイルを保存"""
        unique_filename = self.generate_unique_filename(file.filename)
        file_path = self.uploads_dir / unique_filename

        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)

        return file_path

    def process_uploaded_file(self, file_path: Path) -> Dict[str, Any]:
        """アップロードされたファイルを処理"""
        file_extension = file_path.suffix.lower()
        processed_files = []

        if file_extension == '.pdf':
            # PDFの場合は画像に変換
            image_paths = self.convert_pdf_to_images(file_path)
            processed_files = [path.name for path in image_paths]
        elif file_extension in ['.tif', '.tiff']:
            # TIFの場合はマルチページ対応でPNGに変換
            image_paths = self.convert_tif_to_images(file_path)
            processed_files = [path.name for path in image_paths]
        elif file_extension in ['.jpg', '.jpeg', '.png', '.bmp', '.webp', '.jp2']:
            # 画像ファイルの場合はimagesディレクトリにコピー
            target_path = self.images_dir / file_path.name
            shutil.copy2(file_path, target_path)
            processed_files = [file_path.name]
        else:
            raise HTTPException(status_code=400, detail="サポートされていないファイル形式です")

        return {
            "original_filename": file_path.name,
            "processed_files": processed_files,
            "file_type": "pdf" if file_extension == '.pdf' else ("tif" if file_extension in ['.tif', '.tiff'] else "image")
        }

    def check_ocr_status(self, filename: str) -> Dict[str, Any]:
        """OCR処理の状況を確認"""
        # 元のファイル名から拡張子を除いた部分を取得
        base_name = Path(filename).stem

        # imagesディレクトリに対象ファイルがあるかチェック（処理待ち）
        # マルチページ展開後のページファイル（例: stem_page_001.png）も含めて検索
        images_exist = any(
            file.stem == base_name or file.stem.startswith(base_name + '_page_')
            for file in self.images_dir.glob("*")
        )

        # processディレクトリに処理済み画像があるかチェック
        processed_images = list(self.process_dir.glob(f"*_processed_{base_name}*"))

        # resultディレクトリにCSVファイルがあるかチェック
        result_csv = list(self.result_dir.glob(f"*_result_{base_name}*.csv"))

        if images_exist:
            status = "pending"
        elif processed_images and result_csv:
            status = "completed"
        elif processed_images or result_csv:
            status = "processing"
        else:
            status = "not_found"

        return {
            "filename": filename,
            "status": status,
            "has_processed_image": len(processed_images) > 0,
            "has_result_csv": len(result_csv) > 0,
            "processed_image_files": [img.name for img in processed_images],
            "result_csv_files": [csv.name for csv in result_csv]
        }

    def get_ocr_results(self, filename: str, result_type: str = "both") -> Dict[str, Any]:
        """OCR結果を取得"""
        base_name = Path(filename).stem

        # 処理済み画像とCSVファイルを検索（マルチページ対応）
        processed_images = list(self.process_dir.glob(f"*_processed_{base_name}*"))
        result_csvs = list(self.result_dir.glob(f"*_result_{base_name}*.csv"))

        if not processed_images and not result_csvs:
            raise HTTPException(status_code=404, detail="処理結果が見つかりません")

        result = {
            "filename": filename,
            "timestamp": datetime.now().isoformat()
        }

        if result_type in ["image", "both"] and processed_images:
            result["processed_image"] = processed_images[0].name

        if result_type in ["text", "both"] and result_csvs:
            # CSVファイルを読み込んでJSONとして返す
            csv_data = []
            with open(result_csvs[0], 'r', encoding='utf-8') as csvfile:
                reader = csv.DictReader(csvfile)
                csv_data = list(reader)

            result["ocr_results"] = csv_data
            result["result_csv"] = result_csvs[0].name

        return result

ocr_manager = OCRAPIManager()

@app.post("/upload")
async def upload_file(
    file: UploadFile = File(...),
    email: Optional[str] = Form(None)
):
    """
    ファイルをアップロードしてOCR処理のキューに追加
    """
    try:
        # ファイルサイズチェック（10MB制限）
        if file.size and file.size > 10 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="ファイルサイズが大きすぎます（10MB以下）")

        # ファイルを保存
        saved_file_path = ocr_manager.save_uploaded_file(file)

        # ファイルを処理（PDFから画像変換など）
        process_result = ocr_manager.process_uploaded_file(saved_file_path)

        # アップロード後にオリジナルファイルを削除
        saved_file_path.unlink()

        response = {
            "message": "ファイルのアップロードが完了しました",
            "unique_filename": process_result["original_filename"],
            "processed_files": process_result["processed_files"],
            "file_type": process_result["file_type"],
            "upload_timestamp": datetime.now().isoformat()
        }

        if email:
            response["email"] = email

        return response

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"アップロードエラー: {str(e)}")

@app.get("/status/{filename}")
async def check_status(filename: str):
    """
    OCR処理の状況を確認
    """
    try:
        status_info = ocr_manager.check_ocr_status(filename)
        return status_info
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"ステータス確認エラー: {str(e)}")

@app.get("/result/{filename}")
async def get_results(filename: str, result_type: str = "both"):
    """
    OCR処理結果を取得
    result_type: "image", "text", "both"
    """
    if result_type not in ["image", "text", "both"]:
        raise HTTPException(status_code=400, detail="result_typeは 'image', 'text', 'both' のいずれかである必要があります")

    try:
        results = ocr_manager.get_ocr_results(filename, result_type)
        return results
    except Exception as e:
        if "処理結果が見つかりません" in str(e):
            raise e
        raise HTTPException(status_code=500, detail=f"結果取得エラー: {str(e)}")

@app.get("/download/image/{image_filename}")
async def download_processed_image(image_filename: str):
    """
    処理済み画像をダウンロード
    """
    safe_name = Path(image_filename).name
    image_path = (ocr_manager.process_dir / safe_name).resolve()
    allowed_dir = ocr_manager.process_dir.resolve()

    if not image_path.is_relative_to(allowed_dir):
        raise HTTPException(status_code=400, detail="不正なファイルパスです")

    if not image_path.exists():
        raise HTTPException(status_code=404, detail="画像ファイルが見つかりません")

    return FileResponse(
        path=image_path,
        filename=safe_name,
        media_type="image/png"
    )

@app.get("/download/csv/{csv_filename}")
async def download_csv(csv_filename: str):
    """
    CSVファイルをダウンロード
    """
    safe_name = Path(csv_filename).name
    csv_path = (ocr_manager.result_dir / safe_name).resolve()
    allowed_dir = ocr_manager.result_dir.resolve()

    if not csv_path.is_relative_to(allowed_dir):
        raise HTTPException(status_code=400, detail="不正なファイルパスです")

    if not csv_path.exists():
        raise HTTPException(status_code=404, detail="CSVファイルが見つかりません")

    return FileResponse(
        path=csv_path,
        filename=safe_name,
        media_type="text/csv"
    )

@app.get("/health")
async def health_check():
    """
    API サービス状態確認
    """
    return {"message": "ocr api service is working"}

@app.get("/")
async def root():
    """
    API情報
    """
    return {
        "message": "NDLOCR-Lite API",
        "version": "1.0.0",
        "endpoints": {
            "upload": "POST /upload - ファイルアップロード",
            "status": "GET /status/{filename} - 処理状況確認",
            "result": "GET /result/{filename} - 処理結果取得",
            "download_image": "GET /download/image/{image_filename} - 処理済み画像ダウンロード",
            "download_csv": "GET /download/csv/{csv_filename} - CSVファイルダウンロード"
        }
    }

if __name__ == "__main__":
    import argparse
    import uvicorn

    parser = argparse.ArgumentParser(description="NDLOCR-Lite API Server")
    parser.add_argument("--port", "-p", type=int, default=8000, help="ポート番号 (デフォルト: 8000)")
    parser.add_argument("--host", type=str, default="::", help="ホストアドレス (デフォルト: :: - IPv4/IPv6デュアルスタック)")

    args = parser.parse_args()

    print(f"NDLOCR-Lite API Server を起動中...")
    print(f"ホスト: {args.host}")
    print(f"ポート: {args.port}")
    if args.host == "::":
        print(f"IPv4 URL: http://localhost:{args.port}")
        print(f"IPv6 URL: http://[::1]:{args.port}")
        print(f"IPv4 Swagger UI: http://localhost:{args.port}/docs")
        print(f"IPv6 Swagger UI: http://[::1]:{args.port}/docs")
    else:
        print(f"URL: http://{args.host}:{args.port}")
        print(f"Swagger UI: http://{args.host}:{args.port}/docs")

    uvicorn.run(app, host=args.host, port=args.port)
