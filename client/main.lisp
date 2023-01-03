(require "sb-concurrency")

(defpackage :lsp-backend/client/main
  (:nicknames :lsp-backend/client)
  (:use :cl)
  (:export :start-server-and-connect
           :stop-server))
(in-package :lsp-backend/client/main)

(define-condition give-up-connection-to-server (error)
  ((hostname :initarg :hostname)
   (port :initarg :port))
  (:report (lambda (condition stream)
             (with-slots (hostname port retry-count retry-interval) condition
               (format stream
                       "Give Up connection to server ~A:~D"
                       hostname port)))))

(defstruct continuation id function)

(defclass connection ()
  ((socket
    :initarg :socket
    :reader connection-socket)
   (hostname
    :initarg :hostname
    :reader connection-hostname)
   (port
    :initarg :port
    :reader connection-port)
   (package
    :initform "COMMON-LISP-USER"
    :accessor connection-package)
   (request-id-counter
    :initform 0
    :accessor connection-request-id-counter)
   (continuations
    :initform '()
    :accessor connection-continuations)
   (continuations-mutex
    :initform (sb-thread:make-mutex :name "continuations-mutex")
    :reader connection-continuations-mutex)
   (message-dispatcher-thread
    :accessor connection-message-dispatcher-thread)
   (server-process
    :initform nil
    :accessor connection-server-process)))

(defun new-request-id (connection)
  (incf (connection-request-id-counter connection)))

(defun add-continuation (connection request-id continuation)
  (sb-thread:with-mutex ((connection-continuations-mutex connection))
    (push (make-continuation :id request-id :function continuation)
          (connection-continuations connection))))

(defun get-and-drop-continuation (connection request-id)
  (sb-thread:with-mutex ((connection-continuations-mutex connection))
    (let ((continuation
            (find request-id
                  (connection-continuations connection)
                  :key #'continuation-id)))
      (when continuation
        (setf (connection-continuations connection)
              (remove request-id
                      (connection-continuations connection)
                      :key #'continuation-id))
        continuation))))

(defun socket-connect (hostname port)
  (let ((socket (usocket:socket-connect hostname port :element-type '(unsigned-byte 8))))
    (setf (sb-bsd-sockets:sockopt-keep-alive (usocket:socket socket)) t)
    socket))

(defun create-connection (hostname port)
  (log:debug "socket connect" hostname port)
  (let* ((socket (socket-connect hostname port))
         (connection (make-instance 'connection
                                    :socket socket
                                    :hostname hostname
                                    :port port)))
    (log:debug "socket connected" hostname port)
    connection))

(defun message-waiting-p (connection &key (timeout 0))
  "t if there's a message in the connection waiting to be read, nil otherwise."
  (let* ((socket (connection-socket connection))
         (stream (usocket:socket-stream socket)))

    ;; check stream buffer
    (when (listen stream)
      (return-from message-waiting-p t))

    ;; workaround for windows
    ;;  (usocket:wait-for-input needs WSAResetEvent before call)
    #+(and sbcl win32)
    (when (usocket::wait-list socket)
      (wsa-reset-event
       (usocket::os-wait-list-%wait
        (usocket::wait-list socket))))

    ;; check socket status
    (if (usocket:wait-for-input socket
                                :ready-only t
                                :timeout timeout)
        t
        nil)))

(defun read-message (connection)
  (lsp-backend/rpc:read-message (usocket:socket-stream (connection-socket connection))
                                lsp-backend::*swank-io-package*
                                :validate-input t))

(defun send-message (connection message)
  (lsp-backend/rpc:write-message message
                                 lsp-backend::*swank-io-package*
                                 (usocket:socket-stream (connection-socket connection))))

(defun remote-eval (connection
                    expression
                    &key (package-name (connection-package connection))
                         (thread t)
                         callback)
  (check-type callback function)
  (let ((request-id (new-request-id connection)))
    (add-continuation connection request-id callback)
    (send-message connection
                  `(:emacs-rex
                    ,expression
                    ,package-name
                    ,thread
                    ,request-id))))

(defun call-continuation (connection value request-id)
  (let ((continuation (get-and-drop-continuation connection request-id)))
    (when continuation
      (funcall (continuation-function continuation) value))))

(defun dispatch-waiting-messages (connection)
  (loop :while (message-waiting-p connection)
        :for message := (read-message connection)
        :do (dispatch-message connection message)))

(defun dispatch-message-loop (connection)
  (loop
    (dispatch-waiting-messages connection)))

(defun dispatch-message (connection message)
  (alexandria:destructuring-case message
    ((:return value request-id)
     (call-continuation connection value request-id))))

(defun connect (hostname port)
  (let* ((connection (create-connection hostname port))
         (thread (sb-thread:make-thread #'dispatch-message-loop
                                        :name "lsp-backend/client dispatch-message-loop"
                                        :arguments (list connection))))
    (setf (connection-message-dispatcher-thread connection) thread)
    connection))

(defun connect* (hostname port)
  (loop :for second :in '(0.1 0.2 0.4 0.8 1.6 3.2 6.4)
        :do (sleep second)
            (handler-case (create-connection hostname port)
              (usocket:connection-refused-error ())
              (:no-error (connection)
                (return connection)))
        :finally (error 'give-up-connection-to-server
                        :hostname hostname
                        :port port)))

(defun start-server-and-connect ()
  (let ((port 12345)) ; TODO: Find a random port that is available.
    (let ((process
            (async-process:create-process
             `("ros"
               "run"
               "-s"
               "lsp-backend"
               "-e"
               ,(format nil "(lsp-backend:create-server :dont-close t :port ~D)" port)))))
      (log:debug process (async-process::process-pid process))
      (let* ((connection (connect* "localhost" port))
             (thread (sb-thread:make-thread #'dispatch-message-loop
                                            :name "lsp-backend/client dispatch-message-loop"
                                            :arguments (list connection))))
        (setf (connection-message-dispatcher-thread connection) thread
              (connection-server-process connection) process)
        connection))))

(defun stop-server (connection)
  (sb-thread:terminate-thread (connection-message-dispatcher-thread connection))
  (async-process:delete-process (connection-server-process connection))
  (values))

#|
(log:config :debug)

(defparameter *connection* (start-server-and-connect))

(let ((mailbox (sb-concurrency:make-mailbox)))
  (remote-eval *connection* '(lsp-backend:connection-info)
               :callback (lambda (result)
                           (sb-concurrency:send-message mailbox result)))
  (sb-concurrency:receive-message mailbox))

(stop-server *connection*)
|#
