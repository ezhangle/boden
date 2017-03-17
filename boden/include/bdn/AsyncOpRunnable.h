#ifndef BDN_AsyncOpRunnable_H_
#define BDN_AsyncOpRunnable_H_

#include <bdn/IAsyncOp.h>
#include <bdn/IThreadRunnable.h>


namespace bdn
{


/** A helper for implementing an asynchronous operation.

    This creates a runnable object (IThreadRunnable) that implements the IAsyncOp interface.
    The runnable object can then be executed by a thread or thread pool.

    IAsyncOp can be used to control / abort the operation from other parts of the program. It is
    also used to register notification handlers that are executed when the operation is done and
    to retrieve results ( see onDone() ).

    You use this by deriving a class from AsyncOpRunnable and overriding doOp().

    Note that run() must be called at some point to actually perform the work. The easiest way to do this is to 
    pass the AsyncOpRunnable object to a Thread or ThreadPool object to execute.

    The default implementation only implements the abort functionality (see signalStop()) for cases
    when signalStop is called before doOp() is started. If you want to support stopping during doOp
    then your doOp implementation must call isStopSignalled() regularly and abort with an AbortedError exception
    when it returns true.
*/
template<class ResultType>
class AsyncOpRunnable : public Base, BDN_IMPLEMENTS IAsyncOp<ResultType>, BDN_IMPLEMENTS IThreadRunnable
{
public:
    AsyncOpRunnable()
        : _doneNotifier(this)
    {
    }

    ~AsyncOpRunnable()
    {
        if(_pResult!=nullptr)
            delete _pResult;
    }


    ResultType getResult() const override
    {
        if(!isDone())
            throw UnfinishedError();

        if(_error)
            std::rethrow_exception(_error);

        return *_pResult;
    }       
    
    void signalStop() override
    {
        bool actuallyAborted = false;

        {
            MutexLock lock(_mutex);

            _stopSignalled = true;

            // we cannot abort the operation when it is already in progress
            if(!_started && !_abortedBeforeStart)
            {
                // not started yet. Mark as aborted and set the result
                _abortedBeforeStart = true;
                actuallyAborted = true;

                _error = std::make_exception_ptr(AbortedError());
            }
        }

        if(actuallyAborted)
            _doneNotifier.notify( *this );
    }



    bool isDone() const
    {
        return _doneNotifier.isDone();
    }


    /** Performs the actual operation.
    
        Note that run() will not let exceptions thrown by doOp through.
        Any exception that occurs is stored and will be re-thrown when getResult() is called.*/
    void run() override
    {
        {
            MutexLock lock(_mutex);
            if(_abortedBeforeStart)
            {
                // aborted before we were started => do nothing
                return;
            }

            // mark as started - from this point on aborting is not possible anymore.
            _started = true;
        }

        try
        {        
            _pResult = new ResultType( doOp() );
        }
        catch(...)
        {
            _error = std::current_exception();
        }

        _doneNotifier.notify( *this );
    }


    Notifier<IAsyncOp&>& onDone() const override
    {
        return _doneNotifier;
    }

    

protected:
    /** Override this in derived classes. This should perform the actual synchronous operation.
        */
    virtual ResultType doOp()=0;


    /** Returns true if signalStop() has been called, i.e. if the operation was asked to abort.
        This can be used by the doActualWork() implementation to detect when it should abort.
        That would allow the operation to be aborted while it is in progress.*/
    bool isStopSignalled()
    {
        MutexLock lock(_mutex);
        return _stopSignalled;
    }


private:

    class DoneNotifier : public Notifier<IAsyncOp&>
    {
    public:
        DoneNotifier(IAsyncOp* pOp)
            : _pOpWeak(pOp)
        {            
        }

        void subscribe( P<IBase>& pResultSub, const std::function<void(IAsyncOp&)>& func) override
        {
            MutexLock lock(_mutex);

            // call immediately if we are already done.
            if(_done)
                func(*_pOpWeak);
            else
                Notifier::subscribe(pResultSub, func);
        }

        void notify(IAsyncOp& op) override
        {
            MutexLock lock(_mutex);
            _done = true;

            Notifier::notify(op);
        }

        bool isDone()
        {
            MutexLock lock(_mutex);

            return _done;
        }

    private:
        IAsyncOp*   _pOpWeak = nullptr;
        bool        _done = false;
    };
    
    Mutex                _mutex;
    bool                 _stopSignalled = false;
    bool                 _abortedBeforeStart = false;
    bool                 _started = false;
    mutable DoneNotifier _doneNotifier;

    std::exception_ptr   _error;
    ResultType*          _pResult = nullptr;
};



}

#endif
