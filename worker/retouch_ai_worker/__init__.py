"""Retouch Studio AI worker.

A separate, disposable process that owns every heavy model. The app talks to it
over a Unix socket; nothing here ever writes the user's photo or reaches the
network during a job.
"""
__version__ = "0.1.0"
PROTOCOL_VERSION_STRING = "2"
