defmodule RiceWeb.Api.TaskController do
  @moduledoc "Task V1 的列表、详情和状态动作。"
  use RiceWeb, :controller

  alias Rice.Tasks

  action_fallback(RiceWeb.Api.FallbackController)

  def index(conn, params) do
    render(conn, :index,
      page: Tasks.list_tasks(conn.assigns[:current_user], params),
      current_user: conn.assigns[:current_user]
    )
  end

  def show(conn, %{"id" => id}) do
    with {:ok, task} <- Tasks.fetch_task(id) do
      render(conn, :show, task: task, current_user: conn.assigns[:current_user])
    end
  end

  def create(conn, params) do
    with {:ok, task} <- Tasks.create_task(conn.assigns.current_user, params) do
      conn
      |> put_status(:created)
      |> render(:show, task: task, current_user: conn.assigns.current_user)
    end
  end

  def apply(conn, %{"task_id" => task_id} = params) do
    with {:ok, task} <- Tasks.fetch_task(task_id),
         {:ok, _application} <- Tasks.apply(conn.assigns.current_user, task, params),
         {:ok, task} <- Tasks.fetch_task(task.id) do
      conn
      |> put_status(:created)
      |> render(:show, task: task, current_user: conn.assigns.current_user)
    end
  end

  def appoint(conn, %{"task_id" => task_id, "application_id" => application_id}) do
    with {:ok, task} <- Tasks.fetch_task(task_id),
         {:ok, task} <- Tasks.appoint(conn.assigns.current_user, task, application_id) do
      render(conn, :show, task: task, current_user: conn.assigns.current_user)
    end
  end

  def submit(conn, %{"task_id" => task_id} = params) do
    with {:ok, task} <- Tasks.fetch_task(task_id),
         {:ok, task} <- Tasks.submit_result(conn.assigns.current_user, task, params) do
      conn
      |> put_status(:created)
      |> render(:show, task: task, current_user: conn.assigns.current_user)
    end
  end

  def approve(conn, %{"task_id" => task_id, "submission_id" => submission_id}) do
    with {:ok, task} <- Tasks.fetch_task(task_id),
         {:ok, task} <- Tasks.approve_result(conn.assigns.current_user, task, submission_id) do
      render(conn, :show, task: task, current_user: conn.assigns.current_user)
    end
  end

  def request_changes(
        conn,
        %{"task_id" => task_id, "submission_id" => submission_id} = params
      ) do
    with {:ok, task} <- Tasks.fetch_task(task_id),
         {:ok, task} <-
           Tasks.request_changes(
             conn.assigns.current_user,
             task,
             submission_id,
             params["reason"] || ""
           ) do
      render(conn, :show, task: task, current_user: conn.assigns.current_user)
    end
  end
end
