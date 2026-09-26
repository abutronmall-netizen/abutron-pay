from pathlib import Path
import ast,shutil,sys,time
root=Path(sys.argv[1] if len(sys.argv)>1 else r"C:\Abutron\TradingPlatformV4")
service=root/"abutron"/"service.py"
text=service.read_text(encoding="utf-8")
if "from abutron.quant.engine import QuantEngine" in text:
    print("STEP23Q_SERVICE_ALREADY_PATCHED=True"); raise SystemExit(0)
anchors=["from abutron.kronos_runtime import KronosRuntime","self.kronos=KronosRuntime()",'self._stage(stages,"KRONOS","PASS"',"thesis=create_thesis(symbol,kronos,features,mode,min_conf)",'payload={"kronos":kronos.model_dump(mode="json"),"features":features.model_dump(mode="json"),']
missing=[a for a in anchors if a not in text]
if missing:
    print("STEP23Q_PATCH_ABORT=BASELINE_ANCHOR_MISMATCH")
    [print("MISSING_ANCHOR="+a) for a in missing]
    raise SystemExit(2)
backup=service.with_name("service.py.pre_step23q_"+time.strftime("%Y%m%d-%H%M%S"))
shutil.copy2(service,backup); print("STEP23Q_SERVICE_BACKUP="+str(backup))
text=text.replace("from abutron.kronos_runtime import KronosRuntime","from abutron.kronos_runtime import KronosRuntime\nfrom abutron.quant.engine import QuantEngine",1)
text=text.replace("        self.kronos=KronosRuntime()\n","        self.kronos=KronosRuntime()\n        self.quant=QuantEngine.from_env()\n",1)
old="        self._stage(stages,\"KRONOS\",\"PASS\",f\"direction={kronos.direction.value} score={kronos.score:.4f}\",t)\n\n        t=time.perf_counter()\n        thesis=create_thesis(symbol,kronos,features,mode,min_conf)\n"
new="        self._stage(stages,\"KRONOS\",\"PASS\",f\"direction={kronos.direction.value} score={kronos.score:.4f}\",t)\n\n        # Step 23Q: observational quantitative telemetry only.\n        t=time.perf_counter()\n        quant=self.quant.evaluate(bundle.primary,broker=broker,kronos=kronos,tier=tier)\n        self._stage(stages,\"QUANTITATIVE MATHEMATICS\",\"PASS\" if quant.ok else \"WARN\",quant.stage_detail(),t)\n\n        t=time.perf_counter()\n        thesis=create_thesis(symbol,kronos,features,mode,min_conf)\n"
if old not in text:
    print("STEP23Q_PATCH_ABORT=KRONOS_BLOCK_MISMATCH"); raise SystemExit(3)
text=text.replace(old,new,1)
text=text.replace('        payload={"kronos":kronos.model_dump(mode="json"),"features":features.model_dump(mode="json"),\n','        payload={"kronos":kronos.model_dump(mode="json"),"quant":quant.to_dict(),"features":features.model_dump(mode="json"),\n',1)
ast.parse(text)
service.write_text(text,encoding="utf-8")
ast.parse(service.read_text(encoding="utf-8"))
print("STEP23Q_SERVICE_PATCH=PASS")
print("STEP23Q_SHADOW_ONLY=True")