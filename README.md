# Scratch

## Synopsis

A minimal HTML5 PWA/SPA that implements a dynamic notes space with an OpenAI-powered conversational interface.

## Try it out

[Try it out on GitHub pages](https://sysread.github.io/scratch/).

Note that I had to add `sysread.github.io` to the allow-list in my browser (Opera) as well as my ad-blocker extension.

## Getting started

### Using Docker

```bash
git clone git@github.com:sysread/scratch.git
cd scratch
docker build -t scratch .
docker run -d -p 8080:80 scratch
```

### Manual

This setup requires your own web server. The instructions below use python's built in development server.

```bash
git clone git@github.com:sysread/scratch.git
cd scratch
python -m http.server 8000
```
