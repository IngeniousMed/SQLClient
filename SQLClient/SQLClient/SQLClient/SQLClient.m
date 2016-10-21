//
//  SQLClient.m
//  SQLClient
//
//  Created by Martin Rybak on 10/4/13.
//  Copyright (c) 2013 Martin Rybak. All rights reserved.
//

#import "SQLClient.h"
#import "sybfront.h"
#import "sybdb.h"
#import "syberror.h"

int const SQLClientDefaultTimeout = 5;
int const SQLClientDefaultQueryTimeout = 5;
NSString* const SQLClientDefaultCharset = @"UTF-8";
NSString* const SQLClientWorkerQueueName = @"com.martinrybak.sqlclient";
NSString* const SQLClientDelegateError = @"Delegate must be set to an NSObject that implements the SQLClientDelegate protocol";
NSString* const SQLClientRowIgnoreMessage = @"Ignoring unknown row type";

struct COL
{
	char* name;
	char* buffer;
	int type;
	int size;
	int status;
};

@interface SQLClient ()

@property (nonatomic, copy, readwrite) NSString* host;
@property (nonatomic, copy, readwrite) NSString* username;
@property (nonatomic, copy, readwrite) NSString* database;

@end

@implementation SQLClient
{
	LOGINREC* _login;
	DBPROCESS* _connection;
	char* _password;
}

#pragma mark - NSObject

//Initializes the FreeTDS library and sets callback handlers
- (id)init
{
    if (self = [super init])
    {
        //Initialize the FreeTDS library
		if (dbinit() == FAIL) {
			return nil;
		}
		
		//Initialize SQLClient
		self.timeout = SQLClientDefaultTimeout;
		self.charset = SQLClientDefaultCharset;
		self.callbackQueue = [NSOperationQueue currentQueue];
		self.workerQueue = [[NSOperationQueue alloc] init];
		self.workerQueue.name = SQLClientWorkerQueueName;
		
        //Set FreeTDS callback handlers
        dberrhandle(err_handler);
        dbmsghandle(msg_handler);
    }
    return self;
}

//Exits the FreeTDS library
- (void)dealloc
{
    dbexit();
}

#pragma mark - Public

+ (instancetype)sharedInstance
{
    static SQLClient* sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)connect:(NSString*)host
	   username:(NSString*)username
	   password:(NSString*)password
	   database:(NSString*)database
	 completion:(void (^)(BOOL success))completion
{
	//Save inputs
	self.host = host;
	self.username = username;
	self.database = database;

	/*
	Copy password into a global C string. This is because in connectionSuccess: and connectionFailure:,
	dbloginfree() will attempt to overwrite the password in the login struct with zeroes for security.
	So it must be a string that stays alive until then. Passing in [password UTF8String] does not work because:
		 
	"The returned C string is a pointer to a structure inside the string object, which may have a lifetime
	shorter than the string object and will certainly not have a longer lifetime. Therefore, you should
	copy the C string if it needs to be stored outside of the memory context in which you called this method."
	https://developer.apple.com/library/mac/documentation/Cocoa/Reference/Foundation/Classes/NSString_Class/Reference/NSString.html#//apple_ref/occ/instm/NSString/UTF8String
	 */
	 _password = strdup([password UTF8String]);
	
	//Connect to database on worker queue
	[self.workerQueue addOperationWithBlock:^{
	
		//Set login timeout
		dbsetlogintime(self.timeout);
		
		//Initialize login struct
		_login = dblogin();
		if (_login == FAIL) {
			[self connectionFailure:completion];
			return;
		}
		
		//Populate login struct
		DBSETLUSER(_login, [self.username UTF8String]);
		DBSETLPWD(_login, _password);
		DBSETLHOST(_login, [self.host UTF8String]);
		DBSETLCHARSET(_login, [self.charset UTF8String]);
		
		//Connect to database server
		_connection = dbopen(_login, [self.host UTF8String]);
		if (_connection == NULL) {
			[self connectionFailure:completion];
			return;
		}
		
		//Switch to database
		RETCODE code = dbuse(_connection, [self.database UTF8String]);
		if (code == FAIL) {
			[self connectionFailure:completion];
			return;
		}
	
		//Success!
		[self connectionSuccess:completion];
	}];
}

- (BOOL)isConnected
{
	return !dbdead(_connection);
}

// TODO: how to get number of records changed during update or delete
// TODO: how to handle SQL stored procedure output parameters
- (void)execute:(NSString*)sql completion:(void (^)(NSArray* results))completion
{
	//Execute query on worker queue
	[self.workerQueue addOperationWithBlock:^{
		
		//Set query timeout
		dbsettime(self.timeout);
		
		//Prepare SQL statement
		dbcmd(_connection, [sql UTF8String]);
		
		//Execute SQL statement
		if (dbsqlexec(_connection) == FAIL) {
			[self executionFailure:completion];
			return;
		}
		
		//Create array to contain the tables
		NSMutableArray* output = [NSMutableArray array];
		
		struct COL* columns;
		struct COL* pcol;
		int erc;
		
		//Loop through each table metadata
		//dbresults() returns SUCCEED, FAIL or, NO_MORE_RESULTS.
		while ((erc = dbresults(_connection)) != NO_MORE_RESULTS)
		{
			if (erc == FAIL) {
				[self executionFailure:completion];
				return;
			}
			
			int ncols;
			int row_code;
						
			//Create array to contain the rows for this table
			NSMutableArray* table = [NSMutableArray array];
			
			//Get number of columns
			ncols = dbnumcols(_connection);
			
			//Allocate C-style array of COL structs
			columns = calloc(ncols, sizeof(struct COL));
			if (columns == NULL) {
				[self executionFailure:completion];
				return;
			}
			
			//Bind the column info
			for (pcol = columns; pcol - columns < ncols; pcol++)
			{
				//Get column number
				int c = pcol - columns + 1;
				
				//Get column metadata
				pcol->name = dbcolname(_connection, c);
				pcol->type = dbcoltype(_connection, c);
				
                //For IMAGE data, we need to multiply by 2, because dbbind() will convert each byte to a hexadecimal pair.
                //http://www.freetds.org/userguide/samplecode.htm#SAMPLECODE.RESULTS
                if (pcol->type == SYBIMAGE) {
                    pcol->size = dbcollen(_connection, c) * 2;
                } else {
                    pcol->size = dbcollen(_connection, c);
                }
				
				//If the column is [VAR]CHAR or TEXT, we want the column's defined size, otherwise we want
				//its maximum size when represented as a string, which FreeTDS's dbwillconvert()
				//returns (for fixed-length datatypes). We also do not need to convert IMAGE data type
				if (pcol->type != SYBCHAR && pcol->type != SYBTEXT && pcol->type != SYBIMAGE) {
					pcol->size = dbwillconvert(pcol->type, SYBCHAR);
				}
				
				//Allocate memory in the current pcol struct for a buffer
				pcol->buffer = calloc(1, pcol->size + 1);
				if (pcol->buffer == NULL) {
					[self executionFailure:completion];
					return;
				}
				
				//Bind column name
				erc = dbbind(_connection, c, NTBSTRINGBIND, pcol->size + 1, (BYTE*)pcol->buffer);
				if (erc == FAIL) {
					[self executionFailure:completion];
					return;
				}
				
				//Bind column status
				erc = dbnullbind(_connection, c, &pcol->status);
				if (erc == FAIL) {
					[self executionFailure:completion];
					return;
				}
				
				//printf("%s is type %d with value %s\n", pcol->name, pcol->type, pcol->buffer);
			}
			
			//printf("\n");
			
			//Loop through each row
			while ((row_code = dbnextrow(_connection)) != NO_MORE_ROWS)
			{
				//Check row type
				switch (row_code)
				{
					//Regular row
					case REG_ROW:
					{
						//Create a new dictionary to contain the column names and vaues
						NSMutableDictionary* row = [[NSMutableDictionary alloc] initWithCapacity:ncols];
						
						//Loop through each column and create an entry where dictionary[columnName] = columnValue
						for (pcol = columns; pcol - columns < ncols; pcol++)
						{
							id value;
							
							if (pcol->status == -1) { //null value
								value = [NSNull null];
							} else {
								switch (pcol->type)
								{
									case SYBBIT:
									case SYBBITN:
									{
										bool bit;
										dbbind(_connection, 1, BITBIND, 0, (BYTE*)&bit);
										value = [NSNumber numberWithBool:bit];
										break;
									}
									case SYBINT1:
									case SYBINT2:
									case SYBINT4:
									case SYBINT8:
									case SYBINTN: //nullable
									{
										NSInteger integer;
										dbbind(_connection, 1, INTBIND, 0, (BYTE*)&integer);
										value = [NSNumber numberWithInteger:integer];
										break;
									}
									case SYBFLT8:
									case SYBFLTN: //nullable
									case SYBNUMERIC:
									case SYBREAL:
									{
										CGFloat _float;
										dbbind(_connection, 1, FLT8BIND, 0, (BYTE*)&_float);
										value = [NSNumber numberWithFloat:_float];
										break;
									}
									case SYBMONEY4:
									case SYBMONEY:
									case SYBDECIMAL:
									case SYBMONEYN: //nullable
									{
										//TODO
										//[NSDecimalNumber decimalNumberWithDecimal:nil];
										break;
									}
									case SYBCHAR:
									case SYBVARCHAR:
									case SYBNVARCHAR:
									case SYBTEXT:
									case SYBNTEXT:
									{
										value = [NSString stringWithUTF8String:pcol->buffer];
										break;
									}
									case SYBDATETIME:
									case SYBDATETIME4:
									case SYBDATETIMN:
									case SYBDATE:
									case SYBTIME:
									case SYBBIGDATETIME:
									case SYBBIGTIME:
									case SYBMSDATE:
									case SYBMSTIME:
									case SYBMSDATETIME2:
									case SYBMSDATETIMEOFFSET:
									{
										//TODO
										//NSDate
										break;
									}
									case SYBIMAGE:
									{
										NSString* hexString = [[NSString stringWithUTF8String:pcol->buffer] stringByReplacingOccurrencesOfString:@" " withString:@""];
										NSMutableData* hexData = [[NSMutableData alloc] init];
										
										//Converting hex string to NSData
										unsigned char whole_byte;
										char byte_chars[3] = {'\0','\0','\0'};
										for (int i = 0; i < [hexString length] / 2; i++) {
											byte_chars[0] = [hexString characterAtIndex:i * 2];
											byte_chars[1] = [hexString characterAtIndex:i * 2 + 1];
											whole_byte = strtol(byte_chars, NULL, 16);
											[hexData appendBytes:&whole_byte length:1];
										}
										value = [UIImage imageWithData:hexData];
										break;
									}
									case SYBBINARY:
									case SYBVOID:
									case SYBVARBINARY:
									{
										value = [[NSData alloc] initWithBytes:pcol->buffer length:pcol->size];
										break;
									}
								}
							}
							
							//id value = [NSString stringWithUTF8String:pcol->buffer] ?: [NSNull null];
							NSString* column = [NSString stringWithUTF8String:pcol->name];
							row[column] = value;
                            //printf("%@=%@\n", column, value);
						}
                        
                        //Add an immutable copy to the table
						[table addObject:[row copy]];
						//printf("\n");
						break;
					}
					//Buffer full
					case BUF_FULL:
						[self executionFailure:completion];
						return;
					//Error
					case FAIL:
						[self executionFailure:completion];
						return;
					default:
						[self message:SQLClientRowIgnoreMessage];
						break;
				}
			}
			
			//Clean up
			for (pcol = columns; pcol - columns < ncols; pcol++) {
				free(pcol->buffer);
			}
			free(columns);
			
			//Add immutable copy of table to output
			[output addObject:[table copy]];
		}
		
        //Success! Send an immutable copy of the results array
		[self executionSuccess:completion results:[output copy]];
	}];
}

- (void)disconnect
{
	[self.workerQueue addOperationWithBlock:^{
		dbclose(_connection);
	}];
}

#pragma mark - FreeTDS Callbacks

//Handles message callback from FreeTDS library.
int msg_handler(DBPROCESS* dbproc, DBINT msgno, int msgstate, int severity, char* msgtext, char* srvname, char* procname, int line)
{
	//Can't call self from a C function, so need to access singleton
	SQLClient* self = [SQLClient sharedInstance];
	[self message:[NSString stringWithUTF8String:msgtext]];
	return 0;
}

//Handles error callback from FreeTDS library.
int err_handler(DBPROCESS* dbproc, int severity, int dberr, int oserr, char* dberrstr, char* oserrstr)
{
	//Can't call self from a C function, so need to access singleton
	SQLClient* self = [SQLClient sharedInstance];
	[self error:[NSString stringWithUTF8String:dberrstr] code:dberr severity:severity];
	return INT_CANCEL;
}

#pragma mark - Private

//Invokes connection completion handler on callback queue with success = NO
- (void)connectionFailure:(void (^)(BOOL success))completion
{
    [self.callbackQueue addOperationWithBlock:^{
		if (completion) {
            completion(NO);
		}
    }];
    
    //Cleanup
    dbloginfree(_login);
	free(_password);
}

//Invokes connection completion handler on callback queue with success = [self connected]
- (void)connectionSuccess:(void (^)(BOOL success))completion
{
    [self.callbackQueue addOperationWithBlock:^{
		if (completion) {
            completion([self isConnected]);
		}
    }];
    
    //Cleanup
    dbloginfree(_login);
	free(_password);
}

//Invokes execution completion handler on callback queue with results = nil
- (void)executionFailure:(void (^)(NSArray* results))completion
{
    [self.callbackQueue addOperationWithBlock:^{
		if (completion) {
            completion(nil);
		}
    }];
    
    //Clean up
    dbfreebuf(_connection);
}

//Invokes execution completion handler on callback queue with results array
- (void)executionSuccess:(void (^)(NSArray* results))completion results:(NSArray*)results
{
    [self.callbackQueue addOperationWithBlock:^{
		if (completion) {
            completion(results);
		}
    }];
    
    //Clean up
    dbfreebuf(_connection);
}

//Forwards a message to the delegate on the callback queue if it implements
- (void)message:(NSString*)message
{
	//Invoke delegate on calling queue
	[self.callbackQueue addOperationWithBlock:^{
		if ([self.delegate respondsToSelector:@selector(message:)]) {
			[self.delegate message:message];
		}
	}];
}

//Forwards an error message to the delegate on the callback queue.
- (void)error:(NSString*)error code:(int)code severity:(int)severity
{
	//Invoke delegate on callback queue
	[self.callbackQueue addOperationWithBlock:^{
		if (![self.delegate conformsToProtocol:@protocol(SQLClientDelegate)]) {
			[NSException raise:SQLClientDelegateError format:nil];
		}
		[self.delegate error:error code:code severity:severity];
	}];
}

@end
