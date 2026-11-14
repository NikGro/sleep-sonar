FROM python:3.12-slim
RUN pip install --no-cache-dir cryptography==50.0.2 cbor2==6.2.1
COPY suya_server.py /app/
COPY suya /app/suya
COPY site /site
ENV DATA=/data SITE=/site PORT=8770
USER 1026:100
CMD ["python", "-I", "-u", "/app/suya_server.py"]
