import os
import psycopg2
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

def get_conn():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "todos"),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )


class TodoCreate(BaseModel):
    title: str


class TodoUpdate(BaseModel):
    done: bool


@app.get("/todos")
def list_todos():
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("SELECT id, title, done, created_at FROM todos ORDER BY created_at")
        rows = cur.fetchall()
    return [{"id": r[0], "title": r[1], "done": r[2], "created_at": r[3]} for r in rows]


@app.post("/todos", status_code=201)
def create_todo(body: TodoCreate):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO todos (title) VALUES (%s) RETURNING id, title, done, created_at",
            (body.title,),
        )
        r = cur.fetchone()
    return {"id": r[0], "title": r[1], "done": r[2], "created_at": r[3]}


@app.patch("/todos/{todo_id}")
def update_todo(todo_id: int, body: TodoUpdate):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE todos SET done = %s WHERE id = %s RETURNING id, title, done, created_at",
            (body.done, todo_id),
        )
        r = cur.fetchone()
    if r is None:
        raise HTTPException(status_code=404, detail="Not found")
    return {"id": r[0], "title": r[1], "done": r[2], "created_at": r[3]}


@app.delete("/todos/{todo_id}", status_code=204)
def delete_todo(todo_id: int):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM todos WHERE id = %s RETURNING id", (todo_id,))
        r = cur.fetchone()
    if r is None:
        raise HTTPException(status_code=404, detail="Not found")
