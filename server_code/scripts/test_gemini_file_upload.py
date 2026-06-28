#!/usr/bin/env python3
import os,sys,tempfile
from pathlib import Path
e=Path(__file__).resolve().parent.parent/".env"
if e.exists():
    for L in open(e):
        L=L.strip()
        if L and not L.startswith("#") and "=" in L:
            k,v=L.split("=",1)
            os.environ.setdefault(k.strip(),v.strip().strip('"').strip("'"))
api=os.getenv("GEMINI_API_KEY")
if not api:print("GEMINI_API_KEY");sys.exit(1)
np=os.getenv("GEMINI_FILE_UPLOAD_NO_PROXY","").lower()=="true"
to=int(os.getenv("GEMINI_UPLOAD_TIMEOUT","90"))
print("NO_PROXY=%s timeout=%ds"%(np,to))
with tempfile.NamedTemporaryFile(suffix=".m4a",delete=False) as f:
    f.write(b"\x00"*1024);tp=f.name
try:
    import google.generativeai as genai
    genai.configure(api_key=api)
    if np:
        import google.generativeai.client as g;g.GENAI_API_DISCOVERY_URL="https://generativelanguage.googleapis.com/$discovery/rest"
        print("direct")
    import concurrent.futures,time
    print("upload_file...");st=time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
        u=ex.submit(genai.upload_file,path=tp,display_name="t.m4a",resumable=False)
        r=u.result(timeout=to);print("OK",r.name,time.time()-st)
except concurrent.futures.TimeoutError:print("timeout");sys.exit(1)
except Exception as x:print("err",x);import traceback;traceback.print_exc();sys.exit(1)
finally:os.path.exists(tp)and os.unlink(tp)
print("done")
