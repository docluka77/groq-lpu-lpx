# Cycle-Accurate Python Golden Reference Model (`arch_model/`)

Contains the **1,438-line bit-accurate, cycle-accurate Python Golden Reference Model** ([`groq_golden_model.py`](groq_golden_model.py)) and its **18-test unit verification suite** ([`test_golden_model.py`](test_golden_model.py)).

Run the unit test suite:
```bash
python3 -m unittest discover -s arch_model -p "test_*.py" -v
```

| File | Description |
| :--- | :--- |
| [`groq_golden_model.py`](groq_golden_model.py) | Cycle-accurate golden model of all 8 spatial superlane slices (`ICU`, `MEM`, `SXM`, `VXM`, `MXM`, `NIM`), `Hamming(72,64)` SECDED, `PREC_INT8_RNE`, `NVFP4_E4M3_SCALE`, KV quantizer & EAGLE-2 tree verifier |
| [`test_golden_model.py`](test_golden_model.py) | 18 unit tests covering every slice, numerical rounding edge case (`BUG-LIT-001`..`008`), and multi-chip `RealSync` deskew |
| [`vectors/`](vectors/) | Golden test vectors (`gemv_silu_golden.json`, `llm_decode_layer_golden.json`) and 144-bit VLIW hex programs |
